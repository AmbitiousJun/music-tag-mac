import Foundation
import Darwin

/// A deliberately bounded ISO BMFF/iTunes tag editor. Audio samples are copied verbatim.
enum MP4Tags {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): return "无法编辑 M4A：\(reason)" }
        }
    }

    private struct Atom {
        let type: UInt32
        let start: Int
        let end: Int
        let header: Int
        var body: Int { start + header }
    }

    private struct Metadata {
        let parent: Atom? // udta; nil means the meta is directly in moov
        let meta: Atom
        let ilst: Atom?
    }

    // A bound keeps malformed sizes and unusually large files from exhausting the app.
    private static let maximumFileSize = 512 * 1024 * 1024
    private static let moov: UInt32 = 0x6D6F6F76
    private static let udta: UInt32 = 0x75647461
    private static let meta: UInt32 = 0x6D657461
    private static let ilst: UInt32 = 0x696C7374
    private static let dataType: UInt32 = 0x64617461
    private static let title: UInt32 = 0xA96E616D
    private static let artist: UInt32 = 0xA9415254
    private static let album: UInt32 = 0xA9616C62
    private static let albumArtist: UInt32 = 0x61415254
    private static let composer: UInt32 = 0xA9777274
    private static let genre: UInt32 = 0xA967656E
    private static let numericGenre: UInt32 = 0x676E7265
    private static let year: UInt32 = 0xA9646179
    private static let track: UInt32 = 0x74726B6E
    private static let disc: UInt32 = 0x6469736B
    private static let comment: UInt32 = 0xA9636D74
    private static let lyrics: UInt32 = 0xA96C7972
    private static let artwork: UInt32 = 0x636F7672
    private static let knownTags: Set<UInt32> = [title, artist, album, albumArtist, composer,
                                                genre, numericGenre, year, track, disc,
                                                comment, lyrics, artwork]

    static func read(from url: URL) throws -> AudioTags {
        let bytes = try load(url)
        let root = try atoms(bytes, in: 0..<bytes.count)
        let movie = try uniqueMovie(root)
        let locations = try metadataLocations(bytes, movie: movie)
        var result = AudioTags()
        guard let list = locations.compactMap({ $0.ilst }).first else { return result }
        for tag in try atoms(bytes, in: list.body..<list.end) {
            let lyricistTag = try isLyricist(bytes, tag)
            guard knownTags.contains(tag.type) || lyricistTag else { continue }
            let values = try atoms(bytes, in: tag.body..<tag.end).filter { $0.type == dataType }
            guard let value = values.first, value.end - value.body >= 8 else { continue }
            let kind = uint32(bytes, value.body) & 0x00FF_FFFF
            let payload = bytes.subdata(in: (value.body + 8)..<value.end)
            if tag.type == artwork {
                if (kind == 13 || kind == 14), !payload.isEmpty { result.artwork = payload }
                continue
            }
            if tag.type == track || tag.type == disc {
                guard payload.count >= 6 else { continue }
                let number = uint16(payload, 2)
                let total = uint16(payload, 4)
                let text = total > 0 ? "\(number)/\(total)" : (number > 0 ? "\(number)" : "")
                if tag.type == track { result.track = text } else { result.disc = text }
                continue
            }
            if tag.type == numericGenre {
                if result.genre.isEmpty, payload.count == 2 {
                    let index = Int(uint16(payload, 0)) - 1
                    if index >= 0, index < id3Genres.count { result.genre = id3Genres[index] }
                }
                continue
            }
            let string: String?
            if kind == 1 { string = String(data: payload, encoding: .utf8) }
            else if kind == 2 { string = String(data: payload, encoding: .utf16BigEndian) }
            else { string = nil }
            guard let text = string else { continue }
            if lyricistTag { result.lyricist = text; continue }
            switch tag.type {
            case title: result.title = text
            case artist: result.artist = text
            case album: result.album = text
            case albumArtist: result.albumArtist = text
            case composer: result.composer = text
            case genre: result.genre = text
            case year: result.year = text
            case comment: result.comment = text
            case lyrics: result.lyrics = text
            default: break
            }
        }
        return result
    }

    static func write(_ tags: AudioTags, to url: URL) throws {
        let destination = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let fileAttributes = try manager.attributesOfItem(atPath: destination.path)
        guard (fileAttributes[.type] as? FileAttributeType) == .typeRegular else {
            throw Failure.invalid("目标不是普通文件")
        }
        let original = try load(destination)
        let root = try atoms(original, in: 0..<original.count)
        let movie = try uniqueMovie(root)
        // Fragmentation, compressed movie headers and movie references require a different editor.
        let unsupported: Set<UInt32> = [0x6D6F6F66, 0x6D667261, 0x73696478, 0x73747970]
        guard !root.contains(where: { unsupported.contains($0.type) }) else {
            throw Failure.invalid("暂不支持分片 MP4 或索引片段")
        }
        let media = root.filter { $0.type == 0x6D646174 }
        guard !media.isEmpty else { throw Failure.invalid("找不到音频数据块") }
        let locations = try metadataLocations(original, movie: movie)
        guard locations.count <= 1 else { throw Failure.invalid("存在多组元数据，无法安全确定编辑位置") }
        let oldList = locations.first?.ilst
        var listBody = Data()
        if let list = oldList {
            for child in try atoms(original, in: list.body..<list.end) {
                if !knownTags.contains(child.type), try !isLyricist(original, child) {
                    listBody.append(original.subdata(in: child.start..<child.end))
                }
            }
        }
        let texts: [(UInt32, String)] = [
            (title, tags.title), (artist, tags.artist), (album, tags.album),
            (albumArtist, tags.albumArtist), (composer, tags.composer),
            (genre, tags.genre), (year, tags.year), (comment, tags.comment), (lyrics, tags.lyrics)
        ]
        for (key, text) in texts where !text.isEmpty {
            listBody.append(box(key, valueBox(Data(text.utf8), kind: 1)))
        }
        if !tags.lyricist.isEmpty {
            let mean = box(0x6D65616E, Data(repeating: 0, count: 4) + Data("com.apple.iTunes".utf8))
            let name = box(0x6E616D65, Data(repeating: 0, count: 4) + Data("LYRICIST".utf8))
            listBody.append(box(0x2D2D2D2D, mean + name + valueBox(Data(tags.lyricist.utf8), kind: 1)))
        }
        for (key, text) in [(track, tags.track), (disc, tags.disc)] where !text.isEmpty {
            let pair = try numberPair(text)
            var payload = Data([0, 0])
            append16(pair.0, to: &payload)
            append16(pair.1, to: &payload)
            if key == track { payload.append(contentsOf: [0, 0]) }
            listBody.append(box(key, valueBox(payload, kind: 0)))
        }
        if let image = tags.artwork, !image.isEmpty {
            let kind: UInt32
            if image.starts(with: [0xFF, 0xD8, 0xFF]) { kind = 13 }
            else if image.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { kind = 14 }
            else { throw Failure.invalid("M4A 封面需要 JPEG 或 PNG 格式") }
            guard image.count <= 32 * 1024 * 1024 else { throw Failure.invalid("封面超过 32 MB") }
            listBody.append(box(artwork, valueBox(image, kind: kind)))
        }
        guard listBody.count <= 64 * 1024 * 1024 else { throw Failure.invalid("元数据超过 64 MB 安全上限") }
        let newList = box(ilst, listBody)
        var newMovie = try replaceMetadata(original, movie: movie, location: locations.first, list: newList)
        let difference = newMovie.count - (movie.end - movie.start)
        guard original.count <= maximumFileSize - max(0, difference) else {
            throw Failure.invalid("修改后文件超过 512 MB 安全上限")
        }
        var chunkCount = 0
        let rewrittenMovie = try atoms(newMovie, in: 0..<newMovie.count)[0]
        try patchChunkOffsets(&newMovie, container: rewrittenMovie, originalMovie: movie,
                              media: media, delta: difference, depth: 0, chunkCount: &chunkCount)
        guard chunkCount > 0 else { throw Failure.invalid("找不到可验证的音频块偏移表") }
        var output = Data(capacity: original.count + difference)
        output.append(original.subdata(in: 0..<movie.start))
        output.append(newMovie)
        output.append(original.subdata(in: movie.end..<original.count))
        // Do not overwrite an audio file that changed while it was being prepared.
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".musictag-mp4-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temp.path, contents: nil,
                                 attributes: [.posixPermissions: fileAttributes[.posixPermissions] ?? 0o644]) else {
            throw Failure.invalid("无法在原文件目录建立临时文件")
        }
        defer { try? manager.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: output)
            try handle.synchronize()
            try handle.close()
            let current = try manager.attributesOfItem(atPath: destination.path)
            guard (current[.size] as? NSNumber) == (fileAttributes[.size] as? NSNumber),
                  (current[.modificationDate] as? Date) == (fileAttributes[.modificationDate] as? Date),
                  (current[.systemFileNumber] as? NSNumber) == (fileAttributes[.systemFileNumber] as? NSNumber) else {
                throw Failure.invalid("文件在编辑期间已被其他程序修改，请重新载入")
            }
            if let created = fileAttributes[.creationDate] { try manager.setAttributes([.creationDate: created], ofItemAtPath: temp.path) }
            guard Darwin.rename(temp.path, destination.path) == 0 else {
                throw Failure.invalid(String(cString: strerror(errno)))
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func load(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let length = (attributes[.size] as? NSNumber)?.intValue,
              length >= 8, length <= maximumFileSize else {
            throw Failure.invalid("文件为空、损坏或超过 512 MB 安全上限")
        }
        return try Data(contentsOf: url)
    }

    private static func uniqueMovie(_ root: [Atom]) throws -> Atom {
        let movies = root.filter { $0.type == moov }
        guard movies.count == 1 else { throw Failure.invalid("需要且只能包含一个 moov 数据块") }
        return movies[0]
    }

    private static func atoms(_ bytes: Data, in range: Range<Int>) throws -> [Atom] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw Failure.invalid("数据块范围无效") }
        var result = [Atom]()
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else { throw Failure.invalid("数据块头被截断") }
            let smallSize = uint32(bytes, cursor)
            let type = uint32(bytes, cursor + 4)
            var header = 8
            let length: UInt64
            if smallSize == 1 {
                guard range.upperBound - cursor >= 16 else { throw Failure.invalid("扩展数据块头被截断") }
                header = 16
                length = uint64(bytes, cursor + 8)
            } else if smallSize == 0 { length = UInt64(range.upperBound - cursor) }
            else { length = UInt64(smallSize) }
            guard length >= UInt64(header), length <= UInt64(range.upperBound - cursor) else {
                throw Failure.invalid("数据块长度超出文件范围")
            }
            let end = cursor + Int(length)
            result.append(Atom(type: type, start: cursor, end: end, header: header))
            guard result.count <= 200_000 else { throw Failure.invalid("数据块数量异常") }
            cursor = end
        }
        return result
    }

    private static func metadataLocations(_ bytes: Data, movie: Atom) throws -> [Metadata] {
        var locations = [Metadata]()
        for child in try atoms(bytes, in: movie.body..<movie.end) {
            let candidates: [(Atom?, Atom)]
            if child.type == meta { candidates = [(nil, child)] }
            else if child.type == udta {
                candidates = try atoms(bytes, in: child.body..<child.end).filter { $0.type == meta }.map { (child, $0) }
            } else { continue }
            for (parent, metadata) in candidates {
                guard metadata.end - metadata.body >= 4, bytes[metadata.body] == 0 else {
                    throw Failure.invalid("不支持此 meta 版本")
                }
                let children = try atoms(bytes, in: (metadata.body + 4)..<metadata.end)
                if let handler = children.first(where: { $0.type == 0x68646C72 }) {
                    guard handler.end - handler.body >= 12 else { throw Failure.invalid("元数据处理器被截断") }
                    let kind = uint32(bytes, handler.body + 8)
                    guard kind == 0x6D646972 else {
                        throw Failure.invalid("暂不支持非 iTunes（mdir）元数据结构")
                    }
                }
                let lists = children.filter { $0.type == ilst }
                guard lists.count <= 1 else { throw Failure.invalid("存在重复 ilst 元数据块") }
                locations.append(Metadata(parent: parent, meta: metadata, ilst: lists.first))
            }
        }
        return locations
    }

    private static func replaceMetadata(_ bytes: Data, movie: Atom, location: Metadata?, list: Data) throws -> Data {
        let children = try atoms(bytes, in: movie.body..<movie.end)
        var replacements = [Int: Data]()
        var appendToMovie = Data()
        if let location = location {
            var payload = bytes.subdata(in: location.meta.body..<(location.meta.body + 4))
            let metadataChildren = try atoms(bytes, in: (location.meta.body + 4)..<location.meta.end)
            if !metadataChildren.contains(where: { $0.type == 0x68646C72 }) { payload.append(handlerBox()) }
            for child in metadataChildren {
                if child.type == ilst { payload.append(list) }
                else { payload.append(bytes.subdata(in: child.start..<child.end)) }
            }
            if location.ilst == nil { payload.append(list) }
            let newMeta = box(meta, payload, extended: location.meta.header == 16)
            if let parent = location.parent {
                var parentBody = Data()
                for child in try atoms(bytes, in: parent.body..<parent.end) {
                    parentBody.append(child.start == location.meta.start ? newMeta : bytes.subdata(in: child.start..<child.end))
                }
                replacements[parent.start] = box(udta, parentBody, extended: parent.header == 16)
            } else { replacements[location.meta.start] = newMeta }
        } else {
            let newMeta = box(meta, Data(repeating: 0, count: 4) + handlerBox() + list)
            let parents = children.filter { $0.type == udta }
            guard parents.count <= 1 else { throw Failure.invalid("存在多个 udta 数据块") }
            if let parent = parents.first {
                replacements[parent.start] = box(udta, bytes.subdata(in: parent.body..<parent.end) + newMeta,
                                                 extended: parent.header == 16)
            } else { appendToMovie = box(udta, newMeta) }
        }
        var payload = Data()
        for child in children { payload.append(replacements[child.start] ?? bytes.subdata(in: child.start..<child.end)) }
        payload.append(appendToMovie)
        return box(moov, payload, extended: movie.header == 16)
    }

    private static func patchChunkOffsets(_ bytes: inout Data, container: Atom, originalMovie: Atom,
                                          media: [Atom], delta: Int, depth: Int, chunkCount: inout Int) throws {
        guard depth <= 12 else { throw Failure.invalid("音轨容器嵌套过深") }
        let children = try atoms(bytes, in: container.body..<container.end)
        let containers: Set<UInt32> = [moov, 0x7472616B, 0x6D646961, 0x6D696E66, 0x7374626C, 0x64696E66]
        for child in children {
            if child.type == 0x6D766578 || child.type == 0x636D6F76 || child.type == 0x726D7261 || child.type == 0x7361696F {
                throw Failure.invalid("暂不支持分片、压缩或引用影片")
            }
            if child.type == 0x7374636F || child.type == 0x636F3634 {
                guard child.end - child.body >= 8, uint32(bytes, child.body) == 0 else {
                    throw Failure.invalid("块偏移表版本或标志不受支持")
                }
                let count = Int(uint32(bytes, child.body + 4))
                let width = child.type == 0x7374636F ? 4 : 8
                guard count <= 10_000_000, child.end - child.body - 8 == count * width else {
                    throw Failure.invalid("音频块偏移表长度无效")
                }
                for index in 0..<count {
                    let position = child.body + 8 + index * width
                    let old = width == 4 ? UInt64(uint32(bytes, position)) : uint64(bytes, position)
                    guard media.contains(where: { old >= UInt64($0.body) && old < UInt64($0.end) }) else {
                        throw Failure.invalid("音频偏移不在本地 mdat 数据范围内")
                    }
                    let shifted = old >= UInt64(originalMovie.end)
                    let newValue: UInt64
                    if shifted && delta < 0 {
                        guard old >= UInt64(-delta) else { throw Failure.invalid("音频块偏移下溢") }
                        newValue = old - UInt64(-delta)
                    } else if shifted { newValue = old + UInt64(delta) }
                    else { newValue = old }
                    guard width == 8 || newValue <= UInt64(UInt32.max) else {
                        throw Failure.invalid("修改后的偏移需要更大的 co64 表")
                    }
                    put(newValue, into: &bytes, at: position, count: width)
                }
                chunkCount += count
            } else if child.type == 0x73747364 {
                guard child.end - child.body >= 8 else { throw Failure.invalid("采样描述表被截断") }
                let entries = try atoms(bytes, in: (child.body + 8)..<child.end)
                guard entries.count == Int(uint32(bytes, child.body + 4)),
                      !entries.contains(where: { $0.type == 0x656E6361 || $0.type == 0x656E6376 }) else {
                    throw Failure.invalid("暂不支持加密音轨或无效采样描述")
                }
            } else if child.type == 0x64726566 {
                guard child.end - child.body >= 8 else { throw Failure.invalid("数据引用表被截断") }
                let entries = try atoms(bytes, in: (child.body + 8)..<child.end)
                guard entries.count == Int(uint32(bytes, child.body + 4)), entries.allSatisfy({ entry in
                    entry.type == 0x75726C20 && entry.end - entry.body >= 4 && uint32(bytes, entry.body) == 1
                }) else { throw Failure.invalid("暂不支持外部音频数据引用") }
            } else if containers.contains(child.type) {
                try patchChunkOffsets(&bytes, container: child, originalMovie: originalMovie, media: media,
                                      delta: delta, depth: depth + 1, chunkCount: &chunkCount)
            }
        }
    }

    private static func numberPair(_ text: String) throws -> (UInt16, UInt16) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let number = UInt16(parts[0].trimmingCharacters(in: .whitespaces)),
              parts.count == 1 || UInt16(parts[1].trimmingCharacters(in: .whitespaces)) != nil else {
            throw Failure.invalid("音轨和碟号应为 1 或 1/12，数字范围 0–65535")
        }
        return (number, parts.count == 2 ? UInt16(parts[1].trimmingCharacters(in: .whitespaces))! : 0)
    }

    private static func isLyricist(_ bytes: Data, _ atom: Atom) throws -> Bool {
        guard atom.type == 0x2D2D2D2D else { return false }
        let children = try atoms(bytes, in: atom.body..<atom.end)
        func text(_ type: UInt32) -> String? {
            guard let child = children.first(where: { $0.type == type }), child.end - child.body >= 4 else { return nil }
            return String(data: bytes.subdata(in: (child.body + 4)..<child.end), encoding: .utf8)
        }
        return text(0x6D65616E) == "com.apple.iTunes" && text(0x6E616D65) == "LYRICIST"
    }

    private static func valueBox(_ payload: Data, kind: UInt32) -> Data {
        var body = Data()
        append32(kind, to: &body)
        body.append(contentsOf: [0, 0, 0, 0])
        body.append(payload)
        return box(dataType, body)
    }

    private static func handlerBox() -> Data {
        var payload = Data(repeating: 0, count: 8)
        append32(0x6D646972, to: &payload) // mdir
        payload.append(Data(repeating: 0, count: 13))
        return box(0x68646C72, payload)
    }

    private static func box(_ type: UInt32, _ payload: Data, extended: Bool = false) -> Data {
        var bytes = Data()
        if extended {
            append32(1, to: &bytes)
            append32(type, to: &bytes)
            let count = UInt64(payload.count + 16)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: count >> shift)) }
        } else {
            append32(UInt32(payload.count + 8), to: &bytes)
            append32(type, to: &bytes)
        }
        bytes.append(payload)
        return bytes
    }

    private static func uint16(_ bytes: Data, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    private static func uint32(_ bytes: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
    }
    private static func uint64(_ bytes: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }
    private static func append16(_ number: UInt16, to bytes: inout Data) {
        bytes.append(UInt8(truncatingIfNeeded: number >> 8)); bytes.append(UInt8(truncatingIfNeeded: number))
    }
    private static func append32(_ number: UInt32, to bytes: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: number >> shift)) }
    }
    private static func put(_ number: UInt64, into bytes: inout Data, at offset: Int, count: Int) {
        for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: number >> ((count - index - 1) * 8)) }
    }

    private static let id3Genres = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native US", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "SynthPop"]
}
