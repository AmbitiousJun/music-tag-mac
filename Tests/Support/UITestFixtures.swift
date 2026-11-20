import AppKit
import CryptoKit
import Foundation

/// Shared by XCUITest and the manual Computer Use fixture generator. No network
/// or FFmpeg is needed, and an existing directory is never overwritten.
struct UITestFixtures {
    let root: URL
    let music: URL
    let songs: [URL]
    let cover: URL
    let lyrics: URL
    let audioHashes: [String]

    static func create(at root: URL) throws -> UITestFixtures {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path) else {
            throw FixtureError.invalid("Fixture directory already exists: \(root.path)")
        }
        let music = root.appendingPathComponent("Music", isDirectory: true)
        let nested = music.appendingPathComponent("Nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let songs = [music.appendingPathComponent("01 - First.wav"),
                     music.appendingPathComponent("02 - Second.wav"),
                     nested.appendingPathComponent("03 - Third.wav")]
        for (index, url) in songs.enumerated() {
            try wave(seed: index + 1).write(to: url)
            var tags = AudioTags()
            tags.title = ["First Song", "Second Song", "Third Song"][index]
            tags.artist = "Artist \(index + 1)"
            tags.album = "Original Album \(index + 1)"
            try TagEngine.write(tags, to: url)
        }
        let cover = root.appendingPathComponent("cover.png")
        // Generate RGB artwork with the system encoder, including full decoding
        // support for the app's subsequent TIFF/JPEG conversion.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 24), let pixels = bitmap.bitmapData else {
            throw FixtureError.invalid("Unable to create artwork bitmap")
        }
        for index in 0..<32 * 32 {
            pixels[index * 3] = 32; pixels[index * 3 + 1] = 128; pixels[index * 3 + 2] = 224
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.invalid("Unable to encode artwork PNG")
        }
        try png.write(to: cover)
        let lyrics = root.appendingPathComponent("sample.lrc")
        try "[00:00.00]MusicTag UI test\n[00:01.00]Second line\n".write(to: lyrics, atomically: true, encoding: .utf8)
        let hashes = try songs.map { try audioHash(at: $0) }
        let fixture = UITestFixtures(root: root, music: music, songs: songs, cover: cover, lyrics: lyrics, audioHashes: hashes)
        let manifest: [String: Any] = ["musicDirectory": music.path, "cover": cover.path,
            "lyrics": lyrics.path, "songs": zip(songs, hashes).map { ["path": $0.path, "audioSHA256": $1] }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"))
        return fixture
    }

    /// Independent RIFF chunk reader: validates the exact PCM payload without
    /// using TagEngine's container parser or re-encoding the audio.
    static func audioHash(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw FixtureError.invalid("Invalid WAV header")
        }
        var offset = 12
        while offset + 8 <= data.count {
            let size = (0..<4).reduce(0) { $0 | Int(data[offset + 4 + $1]) << ($1 * 8) }
            let start = offset + 8
            guard size <= data.count - start else { throw FixtureError.invalid("Truncated RIFF chunk") }
            if String(decoding: data[offset..<offset + 4], as: UTF8.self) == "data" {
                return SHA256.hash(data: data[start..<start + size]).map { String(format: "%02x", $0) }.joined()
            }
            offset = start + size + (size & 1)
        }
        throw FixtureError.invalid("Missing PCM data")
    }

    private static func wave(seed: Int) -> Data {
        var pcm = Data()
        // Allow time for several UI actions during playback. Use deterministic
        // 16-bit mono PCM at 8 kHz.
        for index in 0..<160_000 {
            pcm.append(little(UInt32(UInt16(bitPattern: Int16(((index * seed * 37) % 12_000) - 6_000))), count: 2))
        }
        var data = Data("RIFF".utf8)
        data.append(little(UInt32(36 + pcm.count)))
        data.append(Data("WAVEfmt ".utf8))
        data.append(little(16)); data.append(little(1, count: 2)); data.append(little(1, count: 2))
        data.append(little(8_000)); data.append(little(16_000))
        data.append(little(2, count: 2)); data.append(little(16, count: 2))
        data.append(Data("data".utf8)); data.append(little(UInt32(pcm.count))); data.append(pcm)
        return data
    }

    private static func little(_ value: UInt32, count: Int = 4) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    enum FixtureError: Error { case invalid(String) }
}
