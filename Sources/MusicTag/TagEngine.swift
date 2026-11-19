import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct AudioTags: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var composer = ""
    var lyricist = ""
    var genre = ""
    var year = ""
    var track = ""
    var disc = ""
    var comment = ""
    var lyrics = ""
    var artwork: Data? = nil
}

enum TagError: LocalizedError {
    case unsupported(String)
    case invalid(String)
    case write(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "暂不支持写入此格式：\(s)"
        case .invalid(let s): return "音乐文件格式异常：\(s)"
        case .write(let s): return "保存失败：\(s)"
        }
    }
}

/// Container editing only: audio packets are copied byte for byte, never decoded or transcoded.
enum TagEngine {
    static let writableExtensions: Set<String> = ["mp3", "flac", "m4a", "mp4", "wav", "aif", "aiff"]
    static func canWrite(_ url: URL) -> Bool { writableExtensions.contains(url.pathExtension.lowercased()) }

    static func read(from url: URL) throws -> AudioTags {
        if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) { return try MP4Tags.read(from: url) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        switch url.pathExtension.lowercased() {
        case "mp3": return try ID3Tag.parse(data).tags
        case "flac": return try FLACTag.parse(data).tags
        case "wav", "aif", "aiff": return try ChunkTags.parse(data).tags
        default: throw TagError.unsupported(url.pathExtension)
        }
    }

    static func write(_ tags: AudioTags, to url: URL) throws {
        if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) { try MP4Tags.write(tags, to: url); return }
        // Do not follow a symlink during atomic replacement, which would replace the link itself.
        let destination = url.resolvingSymlinksInPath()
        let originalAttributes = try FileManager.default.attributesOfItem(atPath:destination.path)
        let data = try Data(contentsOf: destination, options: .mappedIfSafe)
        let chunks: [Data]
        switch url.pathExtension.lowercased() {
        case "mp3":
            let original = try ID3Tag.parse(data)
            try validateMPEG(data, start: original.audioStart, end: original.audioEnd)
            chunks = [try original.replacing(tags), data.subdata(in: original.audioStart..<original.audioEnd)]
        case "flac": chunks = try FLACTag.parse(data).replacing(tags, source: data)
        case "wav", "aif", "aiff": chunks = [try ChunkTags.parse(data).replacing(tags)]
        default: throw TagError.unsupported(url.pathExtension)
        }
        try atomicWrite(chunks, to: destination, originalAttributes:originalAttributes)
    }

    private static func validateMPEG(_ d: Data, start: Int, end: Int) throws {
        guard start < end else { throw TagError.invalid("MP3 不包含音频数据") }
        let bound = min(end - 3, start + 4096)
        if bound >= start {
            for i in start...bound {
                if d[i] == 0xff && d[i+1] & 0xe0 == 0xe0 && d[i+1] & 0x18 != 0x08 && d[i+1] & 0x06 != 0 && d[i+2] & 0xf0 != 0xf0 && d[i+2] & 0x0c != 0x0c { return }
            }
        }
        throw TagError.invalid("未找到有效 MPEG 音频帧，已停止写入")
    }

    private static func atomicWrite(_ chunks: [Data], to url: URL, originalAttributes before: [FileAttributeKey:Any]) throws {
        let manager = FileManager.default
        guard (before[.type] as? FileAttributeType) == .typeRegular else { throw TagError.write("目标不是普通文件") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".musictag-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: before[.posixPermissions] ?? 0o644]) else { throw TagError.write("无法在音乐文件目录创建临时文件") }
        defer { try? manager.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            for chunk in chunks { try handle.write(contentsOf: chunk) }
            try handle.synchronize()
            try handle.close()
            let after = try manager.attributesOfItem(atPath: url.path)
            guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber), (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date), (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) else { throw TagError.write("保存期间原文件被其他程序修改，请重新载入") }
            // rename on the same volume is atomic; metadata failures occur before replacing the source.
            if let creation = before[.creationDate] { try manager.setAttributes([.creationDate: creation], ofItemAtPath: temp.path) }
            guard Darwin.rename(temp.path, url.path) == 0 else { throw TagError.write(String(cString: strerror(errno))) }
        } catch {
            try? handle.close()
            throw error
        }
    }
}

private enum TagBytes {
    static func be(_ d: Data, _ p: Int, _ n: Int) throws -> Int {
        guard n > 0, p >= 0, p <= d.count - n else { throw TagError.invalid("数据长度不足") }
        var v = 0
        for b in d[p..<p+n] {
            guard v <= (Int.max - Int(b)) / 256 else { throw TagError.invalid("数据长度溢出") }
            v = v * 256 + Int(b)
        }
        return v
    }
    static func le(_ d: Data, _ p: Int, _ n: Int) throws -> Int {
        guard n > 0, p >= 0, p <= d.count - n else { throw TagError.invalid("数据长度不足") }
        var v = 0
        for b in d[p..<p+n].reversed() {
            guard v <= (Int.max - Int(b)) / 256 else { throw TagError.invalid("数据长度溢出") }
            v = v * 256 + Int(b)
        }
        return v
    }
    static func sync(_ d: Data, _ p: Int) throws -> Int {
        guard p >= 0, p <= d.count - 4 else { throw TagError.invalid("ID3 长度不足") }
        var v = 0
        for b in d[p..<p+4] { guard b < 128 else { throw TagError.invalid("ID3 同步安全整数异常") }; v = (v << 7) | Int(b) }
        return v
    }
    static func number(_ v: Int, _ n: Int, little: Bool = false) -> Data {
        var result = Data((0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * (n - 1 - $0))) })
        if little { result.reverse() }
        return result
    }
    static func syncNumber(_ v: Int) -> Data { Data([UInt8((v >> 21) & 127), UInt8((v >> 14) & 127), UInt8((v >> 7) & 127), UInt8(v & 127)]) }
    static func string(_ d: Data) -> String { String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? "" }
    static func unsync(_ d: Data) -> Data {
        var result = Data(); result.reserveCapacity(d.count)
        var i = 0
        while i < d.count { let b = d[i]; result.append(b); i += 1; if b == 255 && i < d.count && d[i] == 0 { i += 1 } }
        return result
    }
    static func image(_ d: Data) -> (String, Int, Int, Int) {
        var mime = d.starts(with: [0x89,0x50,0x4e,0x47]) ? "image/png" : "image/jpeg"
        var width = 0, height = 0, depth = 24
        if let src = CGImageSourceCreateWithData(d as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let type = CGImageSourceGetType(src) { mime = UTType(type as String)?.preferredMIMEType ?? mime }
            width = p[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = p[kCGImagePropertyPixelHeight] as? Int ?? 0
            depth = (p[kCGImagePropertyDepth] as? Int ?? 8) * 3
        }
        return (mime, width, height, depth)
    }
}

private struct ID3Frame {
    var id: String
    var flags: UInt16
    var payload: Data
}

private struct ID3Tag {
    var version = 3
    var frames: [ID3Frame] = []
    var tags = AudioTags()
    var audioStart = 0
    var audioEnd = 0
    static let textMap: [(String, WritableKeyPath<AudioTags, String>)] = [("TIT2", \.title),("TPE1", \.artist),("TALB", \.album),("TPE2", \.albumArtist),("TCOM", \.composer),("TEXT", \.lyricist),("TCON", \.genre),("TYER", \.year),("TDRC", \.year),("TRCK", \.track),("TPOS", \.disc)]
    static let managedIDs = Set(textMap.map { $0.0 } + ["COMM", "USLT", "APIC"])

    static func parse(_ source: Data) throws -> ID3Tag {
        var tag = ID3Tag(); tag.audioEnd = source.count
        // ID3v1 is read as a fallback and removed on write so old values cannot reappear.
        if source.count >= 128 && source.subdata(in: source.count-128..<source.count-125) == Data("TAG".utf8) {
            let p = source.count - 128
            func legacy(_ start: Int, _ length: Int) -> String { (String(data: source.subdata(in: p+start..<p+start+length), encoding: .isoLatin1) ?? "").trimmingCharacters(in: .controlCharacters.union(.whitespaces)) }
            tag.tags.title = legacy(3,30); tag.tags.artist = legacy(33,30); tag.tags.album = legacy(63,30); tag.tags.year = legacy(93,4); tag.tags.comment = legacy(97,30)
            let genres = "Blues|Classic Rock|Country|Dance|Disco|Funk|Grunge|Hip-Hop|Jazz|Metal|New Age|Oldies|Other|Pop|R&B|Rap|Reggae|Rock|Techno|Industrial|Alternative|Ska|Death Metal|Pranks|Soundtrack|Euro-Techno|Ambient|Trip-Hop|Vocal|Jazz+Funk|Fusion|Trance|Classical|Instrumental|Acid|House|Game|Sound Clip|Gospel|Noise|AlternRock|Bass|Soul|Punk|Space|Meditative|Instrumental Pop|Instrumental Rock|Ethnic|Gothic|Darkwave|Techno-Industrial|Electronic|Pop-Folk|Eurodance|Dream|Southern Rock|Comedy|Cult|Gangsta|Top 40|Christian Rap|Pop/Funk|Jungle|Native American|Cabaret|New Wave|Psychadelic|Rave|Showtunes|Trailer|Lo-Fi|Tribal|Acid Punk|Acid Jazz|Polka|Retro|Musical|Rock & Roll|Hard Rock".split(separator:"|")
            let genreIndex = Int(source[p+127]); if genreIndex < genres.count { tag.tags.genre = String(genres[genreIndex]) }
            if source[p+125] == 0 && source[p+126] > 0 { tag.tags.track = String(source[p+126]); tag.tags.comment = legacy(97,28) }
            tag.audioEnd = p
        }
        guard source.count >= 3 && source.prefix(3) == Data("ID3".utf8) else { return tag }
        guard source.count >= 10 else { throw TagError.invalid("ID3 文件头不完整") }
        let version = Int(source[3]); let flags = source[5]
        guard version == 3 || version == 4 else { throw TagError.invalid("目前仅支持安全编辑 ID3v2.3 / v2.4（此文件为 v2.\(version)）") }
        guard source[4] != 255, flags & (version == 3 ? 0x1f : 0x0f) == 0 else { throw TagError.invalid("ID3 头标志异常") }
        let count = try TagBytes.sync(source, 6)
        guard count <= 64 * 1024 * 1024, count <= source.count - 10 else { throw TagError.invalid("ID3 标签长度异常") }
        tag.version = version; tag.audioStart = 10 + count
        var payloadCount = count
        if version == 4 && flags & 0x10 != 0 {
            if count >= 10 && source.subdata(in: tag.audioStart-10..<tag.audioStart-7) == Data("3DI".utf8) { payloadCount -= 10 }
            else if tag.audioStart + 10 <= source.count && source.subdata(in: tag.audioStart..<tag.audioStart+3) == Data("3DI".utf8) { tag.audioStart += 10 }
            else { throw TagError.invalid("ID3v2.4 页脚不完整") }
        }
        guard tag.audioStart <= tag.audioEnd else { throw TagError.invalid("ID3 与音频区域重叠") }
        var body = source.subdata(in: 10..<10+payloadCount)
        if flags & 0x80 != 0 && version == 3 { body = TagBytes.unsync(body) }
        var p = 0
        if flags & 0x40 != 0 {
            let ext = version == 4 ? try TagBytes.sync(body,0) : try TagBytes.be(body,0,4) + 4
            guard ext >= (version == 4 ? 6 : 10), ext <= body.count else { throw TagError.invalid("ID3 扩展头异常") }; p = ext
        }
        while p + 10 <= body.count && body[p] != 0 {
            let idData = body.subdata(in: p..<p+4)
            guard idData.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) }), let id = String(data:idData,encoding:.ascii) else { throw TagError.invalid("ID3 帧名称异常") }
            let length = version == 4 ? try TagBytes.sync(body,p+4) : try TagBytes.be(body,p+4,4)
            let frameFlags = UInt16(try TagBytes.be(body,p+8,2))
            guard length <= body.count-p-10 else { throw TagError.invalid("ID3 帧超出标签边界") }
            var payload = body.subdata(in: p+10..<p+10+length)
            if version == 4 && (frameFlags & 0x0002 != 0 || flags & 0x80 != 0) { payload = TagBytes.unsync(payload) }
            var normalizedFlags = frameFlags
            if version == 4 { normalizedFlags &= ~0x0002 }
            let unsupported = version == 3 ? frameFlags & 0x00c0 != 0 : frameFlags & 0x000c != 0
            if unsupported { throw TagError.invalid("ID3 含压缩或加密帧，已停止写入以保留原始数据") }
            // All frame payload bytes and semantic flags survive unless this is an edited field.
            tag.frames.append(ID3Frame(id:id,flags:normalizedFlags,payload:payload))
            var value = payload
            if version == 3 && frameFlags & 0x0020 != 0 || version == 4 && frameFlags & 0x0040 != 0 { if !value.isEmpty { value.removeFirst(); value = Data(value) } }
            if version == 4 && frameFlags & 0x0001 != 0 { guard value.count >= 4 else { throw TagError.invalid("ID3 数据长度标志异常") }; value = value.subdata(in:4..<value.count) }
            if let mapping = textMap.first(where: { $0.0 == id }) { tag.tags[keyPath:mapping.1] = decodeText(value) }
            else if id == "COMM" { tag.tags.comment = decodeDescribedText(value) }
            else if id == "USLT" { tag.tags.lyrics = decodeDescribedText(value) }
            else if id == "APIC", let image = decodePicture(value) { if tag.tags.artwork == nil || image.0 == 3 { tag.tags.artwork = image.1 } }
            p += 10 + length
        }
        guard body[p...].allSatisfy({ $0 == 0 }) else { throw TagError.invalid("ID3 尾部含无法解析的数据，已停止写入") }
        return tag
    }

    func replacing(_ tags: AudioTags) throws -> Data {
        var outputFrames = frames.filter { !Self.managedIDs.contains($0.id) }
        for (id, path) in Self.textMap where id != (version == 4 ? "TYER" : "TDRC") {
            let value = tags[keyPath:path]
            if !value.isEmpty { outputFrames.append(ID3Frame(id:id,flags:0,payload:Self.encodeText(value))) }
        }
        for (id, value) in [("COMM",tags.comment),("USLT",tags.lyrics)] where !value.isEmpty {
            var payload = Data([1]); payload.append(Data("eng".utf8)); payload.append(contentsOf:[0xff,0xfe,0,0]); payload.append(Self.utf16(value))
            outputFrames.append(ID3Frame(id:id,flags:0,payload:payload))
        }
        if let artwork = tags.artwork, !artwork.isEmpty {
            guard artwork.count <= 32*1024*1024, CGImageSourceCreateWithData(artwork as CFData,nil) != nil else { throw TagError.invalid("封面不是有效图片或超过 32 MB") }
            var payload = Data([0]); payload.append(Data(TagBytes.image(artwork).0.utf8)); payload.append(contentsOf:[0,3,0]); payload.append(artwork)
            outputFrames.append(ID3Frame(id:"APIC",flags:0,payload:payload))
        }
        var body = Data()
        for frame in outputFrames {
            body.append(Data(frame.id.utf8)); body.append(version == 4 ? TagBytes.syncNumber(frame.payload.count) : TagBytes.number(frame.payload.count,4)); body.append(TagBytes.number(Int(frame.flags),2)); body.append(frame.payload)
        }
        body.append(Data(repeating:0,count:1024))
        guard body.count < 0x10000000 else { throw TagError.invalid("标签超过 ID3 容量") }
        var result = Data([0x49,0x44,0x33,UInt8(version),0,0]); result.append(TagBytes.syncNumber(body.count)); result.append(body)
        return result
    }

    private static func utf16(_ s: String) -> Data { var d = Data([0xff,0xfe]); d.append(s.data(using:.utf16LittleEndian) ?? Data()); return d }
    private static func encodeText(_ s: String) -> Data { var d = Data([1]); d.append(utf16(s)); return d }
    private static func decoded(_ d: Data, encoding: UInt8) -> String {
        let s: String
        switch encoding {
        case 0: s = String(data:d,encoding:.isoLatin1) ?? ""
        case 1: s = String(data:d,encoding:.utf16) ?? ""
        case 2: s = String(data:d,encoding:.utf16BigEndian) ?? ""
        case 3: s = String(data:d,encoding:.utf8) ?? ""
        default: s = ""
        }
        return s.trimmingCharacters(in:CharacterSet(charactersIn:"\0")).replacingOccurrences(of:"\0",with:"; ")
    }
    private static func decodeText(_ d: Data) -> String { guard let e = d.first else { return "" }; return decoded(d.subdata(in:1..<d.count),encoding:e) }
    private static func endOfDescription(_ d: Data, from start: Int, encoding: UInt8) -> Int? {
        guard start <= d.count else { return nil }
        if encoding == 1 || encoding == 2 {
            var i = start
            while i+1 < d.count { if d[i] == 0 && d[i+1] == 0 { return i+2 }; i += 2 }
        } else { for i in start..<d.count { if d[i] == 0 { return i+1 } } }
        return nil
    }
    private static func decodeDescribedText(_ d: Data) -> String {
        guard d.count >= 4, let start = endOfDescription(d,from:4,encoding:d[0]) else { return "" }
        return decoded(d.subdata(in:start..<d.count),encoding:d[0])
    }
    private static func decodePicture(_ d: Data) -> (UInt8,Data)? {
        guard d.count > 5, let mimeEnd = d[1...].firstIndex(of:0), mimeEnd+1 < d.count, let imageStart = endOfDescription(d,from:mimeEnd+2,encoding:d[0]), imageStart < d.count else { return nil }
        return (d[mimeEnd+1],d.subdata(in:imageStart..<d.count))
    }
}

private struct FLACBlock { var type: UInt8; var data: Data }
private struct FLACTag {
    var blocks: [FLACBlock]
    var audioStart: Int
    var tags: AudioTags
    var vendor: Data
    var comments: [String]
    static let map: [(String, WritableKeyPath<AudioTags,String>)] = [("TITLE",\.title),("ARTIST",\.artist),("ALBUM",\.album),("ALBUMARTIST",\.albumArtist),("COMPOSER",\.composer),("LYRICIST",\.lyricist),("GENRE",\.genre),("DATE",\.year),("TRACKNUMBER",\.track),("DISCNUMBER",\.disc),("COMMENT",\.comment),("LYRICS",\.lyrics)]

    static func parse(_ source: Data) throws -> FLACTag {
        guard source.count >= 42, source.prefix(4) == Data("fLaC".utf8) else { throw TagError.invalid("FLAC 文件头异常") }
        var blocks: [FLACBlock] = [], tags = AudioTags(), comments: [String] = [], vendor = Data("MusicTag for Mac".utf8), p = 4, last = false, seenComment = false
        var artists: [String] = []
        while !last {
            guard p <= source.count-4, blocks.count < 100000 else { throw TagError.invalid("FLAC 元数据不完整") }
            let type = source[p] & 127; last = source[p] & 128 != 0
            let n = try TagBytes.be(source,p+1,3)
            guard type < 127, n <= source.count-p-4 else { throw TagError.invalid("FLAC 元数据长度异常") }
            if blocks.isEmpty && (type != 0 || n != 34) { throw TagError.invalid("FLAC 缺少 STREAMINFO") }
            let block = source.subdata(in:p+4..<p+4+n)
            blocks.append(FLACBlock(type:type,data:block))
            if type == 4 {
                guard !seenComment else { throw TagError.invalid("FLAC 包含重复 Vorbis Comment 块") }; seenComment = true
                let vn = try TagBytes.le(block,0,4); guard vn <= block.count-4 else { throw TagError.invalid("Vorbis vendor 长度异常") }
                vendor = block.subdata(in:4..<4+vn); var c = 4+vn
                let count = try TagBytes.le(block,c,4); c += 4
                guard count <= 1000000 else { throw TagError.invalid("Vorbis 标签数量异常") }
                for _ in 0..<count {
                    let len = try TagBytes.le(block,c,4); c += 4
                    guard len <= block.count-c, let s = String(data:block.subdata(in:c..<c+len),encoding:.utf8) else { throw TagError.invalid("Vorbis 标签不是有效 UTF-8") }
                    comments.append(s); c += len
                    if let eq = s.firstIndex(of:"=") {
                        let key = s[..<eq].uppercased(); let val = String(s[s.index(after:eq)...])
                        if key == "ARTIST" {
                            if !val.isEmpty { artists.append(val) }
                        } else if let mapping = map.first(where: { $0.0 == key || ($0.0 == "ALBUMARTIST" && key == "ALBUM ARTIST") || ($0.0 == "DATE" && key == "YEAR") || ($0.0 == "COMMENT" && key == "DESCRIPTION") || ($0.0 == "LYRICS" && key == "UNSYNCEDLYRICS") }) { tags[keyPath:mapping.1] = val }
                    }
                }
                guard c == block.count else { throw TagError.invalid("Vorbis Comment 存在无法解析的尾部") }
            } else if type == 6 {
                if let pic = try picture(block), tags.artwork == nil || pic.0 == 3 { tags.artwork = pic.1 }
            }
            p += n+4
        }
        guard p <= source.count-2, source[p] == 0xff, source[p+1] & 0xfc == 0xf8 else { throw TagError.invalid("FLAC 没有有效音频帧") }
        tags.artist = artists.joined(separator: "/")
        // Vorbis stores totals separately; expose the same 3/12 notation as ID3 and MP4.
        for (number,aliases,path) in [(tags.track,["TRACKTOTAL","TOTALTRACKS"],\AudioTags.track),(tags.disc,["DISCTOTAL","TOTALDISCS"],\AudioTags.disc)] where !number.isEmpty && !number.contains("/") {
            if let total = comments.compactMap({ line -> String? in guard let eq = line.firstIndex(of:"="), aliases.contains(line[..<eq].uppercased()) else { return nil }; return String(line[line.index(after:eq)...]) }).first, !total.isEmpty { tags[keyPath:path] = number + "/" + total }
        }
        return FLACTag(blocks:blocks,audioStart:p,tags:tags,vendor:vendor,comments:comments)
    }

    func replacing(_ tags: AudioTags, source: Data) throws -> [Data] {
        let removed = Set(Self.map.map { $0.0 } + ["ALBUM ARTIST","YEAR","DESCRIPTION","UNSYNCEDLYRICS","TRACKTOTAL","TOTALTRACKS","DISCTOTAL","TOTALDISCS"])
        var comments: [String] = [], originalArtists: [String] = []
        for line in self.comments {
            let key = line.firstIndex(of: "=").map { line[..<$0].uppercased() } ?? ""
            if !removed.contains(key) { comments.append(line) }
            if key == "ARTIST", tags.artist == self.tags.artist { originalArtists.append(line) }
        }
        for (name,path) in Self.map {
            if name == "ARTIST", !originalArtists.isEmpty {
                comments.append(contentsOf: originalArtists)
                continue
            }
            let value = tags[keyPath:path]
            guard !value.isEmpty else { continue }
            if name == "TRACKNUMBER" || name == "DISCNUMBER", let slash = value.firstIndex(of:"/") {
                comments.append(name + "=" + value[..<slash]); let total = value[value.index(after:slash)...]
                if !total.isEmpty { comments.append((name == "TRACKNUMBER" ? "TRACKTOTAL=" : "DISCTOTAL=") + total) }
            } else { comments.append(name + "=" + value) }
        }
        var comment = TagBytes.number(vendor.count,4,little:true); comment.append(vendor); comment.append(TagBytes.number(comments.count,4,little:true))
        for line in comments { let bytes = Data(line.utf8); comment.append(TagBytes.number(bytes.count,4,little:true)); comment.append(bytes) }
        var output = blocks.filter { $0.type != 4 && $0.type != 6 && $0.type != 1 }
        output.insert(FLACBlock(type:4,data:comment),at:1)
        if let artwork = tags.artwork, !artwork.isEmpty {
            guard artwork.count <= 0xffffff-128, CGImageSourceCreateWithData(artwork as CFData,nil) != nil else { throw TagError.invalid("封面不是有效图片或超过 FLAC 块大小限制") }
            let (mime,w,h,depth) = TagBytes.image(artwork), mimeData = Data(mime.utf8)
            var pic = TagBytes.number(3,4); pic.append(TagBytes.number(mimeData.count,4)); pic.append(mimeData); pic.append(TagBytes.number(0,4))
            for value in [w,h,depth,0,artwork.count] { pic.append(TagBytes.number(value,4)) }; pic.append(artwork)
            output.append(FLACBlock(type:6,data:pic))
        }
        output.append(FLACBlock(type:1,data:Data(repeating:0,count:1024)))
        var metadata = Data("fLaC".utf8)
        for (index,block) in output.enumerated() {
            guard block.data.count <= 0xffffff else { throw TagError.invalid("FLAC 元数据块超过 16 MB") }
            metadata.append(block.type | (index == output.count-1 ? 128 : 0)); metadata.append(TagBytes.number(block.data.count,3)); metadata.append(block.data)
        }
        return [metadata,source.subdata(in:audioStart..<source.count)]
    }

    private static func picture(_ d: Data) throws -> (Int,Data)? {
        let type = try TagBytes.be(d,0,4), mimeCount = try TagBytes.be(d,4,4)
        guard mimeCount <= d.count-8 else { throw TagError.invalid("FLAC 封面 MIME 长度异常") }
        let mime = TagBytes.string(d.subdata(in:8..<8+mimeCount)); var p = 8+mimeCount
        let descCount = try TagBytes.be(d,p,4); p += 4
        guard descCount <= d.count-p else { throw TagError.invalid("FLAC 封面描述长度异常") }; p += descCount
        guard p <= d.count-20 else { throw TagError.invalid("FLAC 封面头不完整") }; p += 16
        let size = try TagBytes.be(d,p,4); p += 4
        guard size == d.count-p else { throw TagError.invalid("FLAC 封面长度异常") }
        return mime == "-->" ? nil : (type,d.subdata(in:p..<d.count))
    }
}

private struct AudioChunk { var id: Data; var payload: Data }
private struct ChunkTags {
    var isWAV: Bool
    var kind: Data
    var chunks: [AudioChunk]
    var tags: AudioTags
    var id3: ID3Tag?
    static let infoMap: [(String,WritableKeyPath<AudioTags,String>)] = [("INAM",\.title),("IART",\.artist),("IPRD",\.album),("ICRD",\.year),("IGNR",\.genre),("ICMT",\.comment),("ITRK",\.track)]
    static let aiffMap: [(String,WritableKeyPath<AudioTags,String>)] = [("NAME",\.title),("AUTH",\.artist),("ANNO",\.comment)]
    static func infoChunks(_ d: Data) throws -> [AudioChunk] {
        guard d.count >= 4, d.prefix(4) == Data("INFO".utf8) else { return [] }
        var p = 4, chunks: [AudioChunk] = []
        while p < d.count {
            guard p <= d.count-8 else { throw TagError.invalid("WAVE INFO 块不完整") }
            let n = try TagBytes.le(d,p+4,4)
            guard n <= d.count-p-8 else { throw TagError.invalid("WAVE INFO 长度异常") }
            chunks.append(AudioChunk(id:d.subdata(in:p..<p+4),payload:d.subdata(in:p+8..<p+8+n)))
            p += 8+n+(n%2)
        }
        guard p == d.count else { throw TagError.invalid("WAVE INFO 填充不完整") }
        return chunks
    }
    static func parse(_ source: Data) throws -> ChunkTags {
        guard source.count >= 12 else { throw TagError.invalid("音频容器头不完整") }
        let wav = source.prefix(4) == Data("RIFF".utf8), aiff = source.prefix(4) == Data("FORM".utf8)
        let kind = source.subdata(in:8..<12)
        guard wav && kind == Data("WAVE".utf8) || aiff && [Data("AIFF".utf8),Data("AIFC".utf8)].contains(kind) else { throw TagError.invalid("仅支持标准 RIFF WAVE / AIFF 容器") }
        let declared = wav ? try TagBytes.le(source,4,4) : try TagBytes.be(source,4,4)
        guard declared == source.count-8 else { throw TagError.invalid("容器长度不一致，已停止写入") }
        var chunks: [AudioChunk] = [], p = 12, tags = AudioTags(), embedded: ID3Tag? = nil, audioFound = false, formatFound = false
        while p < source.count {
            guard p <= source.count-8 else { throw TagError.invalid("音频块头不完整") }
            let id = source.subdata(in:p..<p+4), n = wav ? try TagBytes.le(source,p+4,4) : try TagBytes.be(source,p+4,4)
            guard n <= source.count-p-8 else { throw TagError.invalid("音频块长度异常") }
            let d = source.subdata(in:p+8..<p+8+n)
            if id == Data("id3 ".utf8) || id == Data("ID3 ".utf8) { embedded = try ID3Tag.parse(d) }
            if wav && id == Data("LIST".utf8) {
                for item in try infoChunks(d) {
                    if let pair = infoMap.first(where: { Data($0.0.utf8) == item.id }) { tags[keyPath:pair.1] = TagBytes.string(item.payload).trimmingCharacters(in:.controlCharacters) }
                }
            } else if !wav, let pair = aiffMap.first(where: { Data($0.0.utf8) == id }) { tags[keyPath:pair.1] = TagBytes.string(d).trimmingCharacters(in:.controlCharacters) }
            if id == Data((wav ? "data" : "SSND").utf8) { audioFound = n > (wav ? 0 : 8) }
            if id == Data((wav ? "fmt " : "COMM").utf8) { formatFound = n >= (wav ? 16 : 18) }
            chunks.append(AudioChunk(id:id,payload:d)); p += 8+n+(n%2)
        }
        guard p == source.count, audioFound, formatFound else { throw TagError.invalid("音频或格式信息块不完整或缺失") }
        return ChunkTags(isWAV:wav,kind:kind,chunks:chunks,tags:embedded?.tags ?? tags,id3:embedded)
    }
    func replacing(_ tags: AudioTags) throws -> Data {
        var chunks = self.chunks.filter { $0.id != Data("id3 ".utf8) && $0.id != Data("ID3 ".utf8) }
        if isWAV {
            // Keep INFO and ID3 consistent for readers which prefer the legacy RIFF fields.
            let known = Set(Self.infoMap.map { $0.0 })
            var unknown: [AudioChunk] = []
            for chunk in chunks where chunk.id == Data("LIST".utf8) && chunk.payload.starts(with:Data("INFO".utf8)) {
                unknown.append(contentsOf:try Self.infoChunks(chunk.payload).filter { !known.contains(TagBytes.string($0.id)) })
            }
            chunks.removeAll { $0.id == Data("LIST".utf8) && $0.payload.starts(with:Data("INFO".utf8)) }
            for (key,path) in Self.infoMap where !tags[keyPath:path].isEmpty { var d = Data(tags[keyPath:path].utf8); d.append(0); unknown.append(AudioChunk(id:Data(key.utf8),payload:d)) }
            if !unknown.isEmpty {
                var info = Data("INFO".utf8)
                for item in unknown { info.append(item.id); info.append(TagBytes.number(item.payload.count,4,little:true)); info.append(item.payload); if item.payload.count%2 == 1 { info.append(0) } }
                chunks.append(AudioChunk(id:Data("LIST".utf8),payload:info))
            }
        } else {
            let known = Set(Self.aiffMap.map { $0.0 })
            chunks.removeAll { known.contains(TagBytes.string($0.id)) }
            for (key,path) in Self.aiffMap where !tags[keyPath:path].isEmpty { chunks.append(AudioChunk(id:Data(key.utf8),payload:Data(tags[keyPath:path].utf8))) }
        }
        let id3 = try (self.id3 ?? ID3Tag()).replacing(tags)
        chunks.append(AudioChunk(id:Data((isWAV ? "id3 " : "ID3 ").utf8),payload:id3))
        var body = kind
        for chunk in chunks { body.append(chunk.id); body.append(TagBytes.number(chunk.payload.count,4,little:isWAV)); body.append(chunk.payload); if chunk.payload.count%2 == 1 { body.append(0) } }
        guard body.count <= 0xffffffff else { throw TagError.invalid("容器超过 4 GB；不支持 RF64") }
        var output = Data((isWAV ? "RIFF" : "FORM").utf8); output.append(TagBytes.number(body.count,4,little:isWAV)); output.append(body)
        return output
    }
}
