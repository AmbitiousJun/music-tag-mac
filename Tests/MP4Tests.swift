// Standalone integration test (uses ffmpeg/ffprobe only to make and independently verify fixtures):
// Run with scripts/test.sh; tests exercise the same TagEngine entry points as the app.
// /tmp/MP4Tests /absolute/path/to/ffmpeg /absolute/path/to/ffprobe
import Foundation
import CryptoKit

@main
struct MP4IntegrationTests {
    struct TestError: Error, CustomStringConvertible { let description: String }
    struct Box { let start: Int; let size: Int; let header: Int; let kind: UInt32
        var body: Int { start + header }; var end: Int { start + size }
    }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TestError(description: message) }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe(), errors = Pipe()
        task.standardOutput = output; task.standardError = errors
        try task.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw TestError(description: "\(executable) failed: \(String(decoding: stderr, as: UTF8.self))")
        }
        return bytes
    }
    static func u32(_ data: Data, _ p: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(data[p + $1]) }
    }
    static func u64(_ data: Data, _ p: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(data[p + $1]) }
    }
    static func integer(_ x: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: x >> ((width - $0 - 1) * 8)) })
    }
    static func boxes(_ data: Data, _ range: Range<Int>) -> [Box] {
        var output = [Box](), p = range.lowerBound
        while p + 8 <= range.upperBound {
            let small = u32(data, p), header = small == 1 ? 16 : 8
            let size = small == 1 ? Int(u64(data, p + 8)) : small == 0 ? range.upperBound - p : Int(small)
            guard size >= header, size <= range.upperBound - p else { break }
            output.append(Box(start: p, size: size, header: header, kind: u32(data, p + 4)))
            p += size
        }
        return output
    }
    static func box(_ kind: UInt32, _ body: Data, extended: Bool = false) -> Data {
        if extended { return integer(1, width: 4) + integer(UInt64(kind), width: 4) + integer(UInt64(body.count + 16), width: 8) + body }
        return integer(UInt64(body.count + 8), width: 4) + integer(UInt64(kind), width: 4) + body
    }
    static func mediaHash(_ data: Data) -> String {
        var hash = SHA256()
        for atom in boxes(data, 0..<data.count) where atom.kind == 0x6D646174 {
            hash.update(data: data.subdata(in: atom.body..<atom.end))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func audioHash(_ url: URL, ffmpeg: String) throws -> Data {
        try run(ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "hash", "-hash", "sha256", "-"])
    }
    static func encoderAtom(_ data: Data) -> Data? {
        let key = Data([0xA9, 0x74, 0x6F, 0x6F])
        guard let match = data.range(of: key), match.lowerBound >= 4 else { return nil }
        let start = match.lowerBound - 4, size = Int(u32(data, start))
        guard size >= 8, start + size <= data.count else { return nil }
        return data.subdata(in: start..<(start + size))
    }
    static func movieTransform(_ source: Data, co64: Bool = false, removeMetadata: Bool = false,
                               extended: Bool = false, directMetadata: Bool = false) throws -> Data {
        let movie = boxes(source, 0..<source.count).first { $0.kind == 0x6D6F6F76 }!
        let containers: Set<UInt32> = [0x6D6F6F76, 0x7472616B, 0x6D646961, 0x6D696E66, 0x7374626C]
        func rebuild(_ atom: Box) -> Data {
            if co64, atom.kind == 0x7374636F {
                let count = Int(u32(source, atom.body + 4))
                var payload = source.subdata(in: atom.body..<(atom.body + 8))
                for index in 0..<count { payload.append(integer(UInt64(u32(source, atom.body + 8 + index * 4)), width: 8)) }
                return box(0x636F3634, payload)
            }
            if containers.contains(atom.kind) {
                var payload = Data()
                for child in boxes(source, atom.body..<atom.end) {
                    if child.kind == 0x75647461 {
                        if removeMetadata { continue }
                        if directMetadata {
                            for entry in boxes(source, child.body..<child.end) { payload.append(source.subdata(in: entry.start..<entry.end)) }
                            continue
                        }
                    }
                    payload.append(rebuild(child))
                }
                return box(atom.kind, payload, extended: extended && atom.kind == 0x6D6F6F76)
            }
            return source.subdata(in: atom.start..<atom.end)
        }
        var updatedMovie = rebuild(movie)
        let delta = updatedMovie.count - movie.size
        func adjust(_ atom: Box, _ data: inout Data) {
            if atom.kind == 0x7374636F || atom.kind == 0x636F3634 {
                let width = atom.kind == 0x7374636F ? 4 : 8, count = Int(u32(data, atom.body + 4))
                for i in 0..<count {
                    let p = atom.body + 8 + i * width
                    let old = width == 4 ? Int(u32(data, p)) : Int(u64(data, p))
                    let replacement = old >= movie.end ? old + delta : old
                    data.replaceSubrange(p..<(p + width), with: integer(UInt64(replacement), width: width))
                }
            } else if containers.contains(atom.kind) {
                for child in boxes(data, atom.body..<atom.end) { adjust(child, &data) }
            }
        }
        adjust(boxes(updatedMovie, 0..<updatedMovie.count)[0], &updatedMovie)
        return source.subdata(in: 0..<movie.start) + updatedMovie + source.subdata(in: movie.end..<source.count)
    }
    static func mustReject(_ tags: AudioTags, _ url: URL, _ description: String) throws {
        let before = try Data(contentsOf: url)
        do {
            try TagEngine.write(tags, to: url)
            throw TestError(description: "Expected rejection: \(description)")
        } catch is MP4Tags.Failure { }
        try require(try Data(contentsOf: url) == before, "Rejected edit changed the file: \(description)")
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw TestError(description: "Usage: MP4Tests /absolute/path/to/ffmpeg /absolute/path/to/ffprobe")
        }
        let ffmpeg = CommandLine.arguments[1], ffprobe = CommandLine.arguments[2]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicTag-MP4Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var tags = AudioTags()
        tags.title = "月光 · Native Swift"; tags.artist = "测试艺术家"; tags.album = "Album ∞"
        tags.albumArtist = "Various Artists"; tags.composer = "作曲者"; tags.genre = "Jazz"
        tags.year = "2026-11-15"; tags.track = "3/12"; tags.disc = "2/3"
        tags.comment = "line one\n第二行"; tags.lyrics = "[00:00.00] 原样歌词\n[00:01.00] Hello"
        tags.lyricist = "作词家"
        tags.artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        var tested = 0
        var seed: Data?
        for codec in ["aac", "alac"] {
            for fast in [false, true] {
                let name = "\(codec)-\(fast ? "moov-first" : "moov-last")"
                let url = root.appendingPathComponent(name + ".m4a")
                var arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=44100:duration=0.35", "-c:a", codec,
                                 "-metadata", "title=Original", "-metadata", "artist=Old Artist", "-metadata", "track=1/10"]
                if fast { arguments += ["-movflags", "+faststart"] }
                _ = try run(ffmpeg, arguments + [url.path])
                try require(TagEngine.canWrite(url), "App entry point must expose M4A editing")
                let original = try Data(contentsOf: url)
                if fast && codec == "aac" { seed = original }
                let originalAudioHash = try audioHash(url, ffmpeg: ffmpeg)
                let originalMediaHash = mediaHash(original)
                let encoder = encoderAtom(original)
                try require(try TagEngine.read(from: url).title == "Original", "Initial metadata read failed")
                try TagEngine.write(tags, to: url)
                let updated = try Data(contentsOf: url), reread = try TagEngine.read(from: url)
                try require(reread.title == tags.title && reread.artist == tags.artist && reread.album == tags.album,
                            "Text tag round trip failed: \(name)")
                try require(reread.albumArtist == tags.albumArtist && reread.composer == tags.composer && reread.lyricist == tags.lyricist,
                            "Credit tag round trip failed: \(name)")
                try require(reread.genre == tags.genre && reread.year == tags.year && reread.track == tags.track && reread.disc == tags.disc,
                            "Number tag round trip failed: \(name)")
                try require(reread.comment == tags.comment && reread.lyrics == tags.lyrics && reread.artwork == tags.artwork,
                            "Comment, lyrics or cover round trip failed: \(name)")
                try require(mediaHash(updated) == originalMediaHash, "mdat bytes changed: \(name)")
                try require(encoderAtom(updated) == encoder, "Unknown ©too atom changed: \(name)")
                try require(try audioHash(url, ffmpeg: ffmpeg) == originalAudioHash, "Decoded PCM changed: \(name)")
                let probe = try run(ffprobe, ["-v", "error", "-show_entries", "format_tags", "-of", "json", url.path])
                let json = try JSONSerialization.jsonObject(with: probe) as! [String: Any]
                let observed = (json["format"] as! [String: Any])["tags"] as! [String: String]
                for (key, expected) in [("title", tags.title), ("artist", tags.artist), ("album", tags.album),
                                        ("album_artist", tags.albumArtist), ("composer", tags.composer),
                                        ("genre", tags.genre), ("date", tags.year), ("track", tags.track),
                                        ("disc", tags.disc), ("comment", tags.comment), ("lyrics", tags.lyrics), ("LYRICIST", tags.lyricist)] {
                    try require(observed[key] == expected, "ffprobe disagrees on \(key): \(String(describing: observed[key]))")
                }
                try TagEngine.write(AudioTags(), to: url)
                let cleared = try TagEngine.read(from: url)
                try require(cleared.title.isEmpty && cleared.lyrics.isEmpty && cleared.lyricist.isEmpty && cleared.artwork == nil,
                            "Clear tags failed: \(name)")
                try require(mediaHash(try Data(contentsOf: url)) == originalMediaHash, "Clearing tags changed samples")
                try require(try audioHash(url, ffmpeg: ffmpeg) == originalAudioHash, "Clearing tags changed decoded audio")
                print("PASS \(name): UTF-8, all tags, PNG artwork, grow/shrink, unknown atoms, mdat SHA-256 and decoded PCM SHA-256")
                tested += 1
            }
        }
        for (name, transformed) in [
            ("co64", try movieTransform(seed!, co64: true)),
            ("missing-metadata", try movieTransform(seed!, removeMetadata: true)),
            ("extended-moov", try movieTransform(seed!, extended: true)),
            ("direct-moov-meta", try movieTransform(seed!, directMetadata: true))
        ] {
            let url = root.appendingPathComponent(name + ".m4a")
            try transformed.write(to: url)
            let before = try audioHash(url, ffmpeg: ffmpeg)
            try TagEngine.write(tags, to: url)
            try require(try TagEngine.read(from: url).title == tags.title, "Special layout tag read failed: \(name)")
            try require(mediaHash(try Data(contentsOf: url)) == mediaHash(transformed), "Special layout changed mdat: \(name)")
            try require(try audioHash(url, ffmpeg: ffmpeg) == before, "Special layout changed PCM: \(name)")
            print("PASS \(name): metadata, mdat and independently decoded PCM")
            tested += 1
        }
        let fragment = root.appendingPathComponent("fragment.m4a")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=duration=0.1", "-c:a", "aac", "-movflags", "+frag_keyframe+empty_moov+default_base_moof", fragment.path])
        try mustReject(tags, fragment, "fragmented MP4")
        let invalid = root.appendingPathComponent("invalid.m4a")
        try Data([0xFF, 0xFF, 0xFF, 0xFF, 0x6D, 0x6F, 0x6F, 0x76]).write(to: invalid)
        try mustReject(tags, invalid, "out-of-bounds atom")
        let valid = root.appendingPathComponent("validation.m4a")
        try seed!.write(to: valid)
        var badTags = tags; badTags.track = "1/no"
        try mustReject(badTags, valid, "invalid track number")
        badTags = tags; badTags.artwork = Data([1, 2, 3])
        try mustReject(badTags, valid, "invalid artwork")
        for (key, replacement, relative, description) in [
            (Data("stco".utf8), Data(repeating: 0, count: 4), 8, "chunk offset outside mdat"),
            (Data("url ".utf8), Data([0, 0, 0, 0]), 0, "external data reference"),
            (Data("mp4a".utf8), Data("enca".utf8), -4, "encrypted audio sample entry")
        ] {
            var broken = seed!
            let found = broken.range(of: key)!
            let start = found.upperBound + relative
            broken.replaceSubrange(start..<(start + replacement.count), with: replacement)
            try broken.write(to: invalid)
            try mustReject(tags, invalid, description)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: valid.path)
        let link = root.appendingPathComponent("linked.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        try TagEngine.write(tags, to: link)
        let mode = try FileManager.default.attributesOfItem(atPath: valid.path)[.posixPermissions] as! NSNumber
        let linkKind = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as! FileAttributeType
        try require(mode.intValue == 0o640 && linkKind == .typeSymbolicLink, "Atomic replacement lost file permissions or replaced a symlink")
        try require(try TagEngine.read(from: valid).title == tags.title, "Symlink did not update its target")
        print("PASS safe rejection: fragments, malformed atoms, invalid input, external/out-of-bounds references and encryption; originals unchanged")
        print("PASS atomic replacement: symlink preserved, target updated, original POSIX mode preserved")
        print("SUCCESS: \(tested) layout/codec integration cases plus safe-rejection cases")
    }
}
