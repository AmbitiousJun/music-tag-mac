import Foundation
import CryptoKit
import AppKit

@main struct TagEngineTests {
    static func run(_ args: [String], tool: String = "ffmpeg") throws -> String {
        let variable = tool == "ffmpeg" ? "FFMPEG" : "FFPROBE"
        let p = Process(); p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[variable]!); p.arguments = args
        let output = Pipe(); let errors = Pipe(); p.standardOutput = output; p.standardError = errors
        try p.run(); let result = output.fileHandleForReading.readDataToEndOfFile(); let diagnostics = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain:"FFmpeg",code:Int(p.terminationStatus),userInfo:[NSLocalizedDescriptionKey:String(decoding:diagnostics,as:UTF8.self)]) }
        return String(decoding:result,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func check(_ passed: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try passed() else { throw NSError(domain:"TagTests",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func audioHash(_ url: URL) throws -> String { try run(["-v","error","-i",url.path,"-map","0:a:0","-f","hash","-hash","sha256","-"]) }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "analysis/tests",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let image = NSImage(size:NSSize(width:8,height:8)); image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x:0,y:0,width:8,height:8).fill(); image.unlockFocus()
        let artwork = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        var updated = AudioTags(); updated.title = "测试标题 🎵"; updated.artist = "测试歌手"; updated.album = "Album"; updated.albumArtist = "Various"; updated.composer = "Composer"; updated.lyricist = "Lyricist"; updated.genre = "Jazz"; updated.year = "2026"; updated.track = "3/12"; updated.disc = "1/2"; updated.comment = "A comment"; updated.lyrics = "[00:01.00]第一行\n[00:03.00]第二行"; updated.artwork = artwork
        for (ext,codec) in [("mp3","libmp3lame"),("flac","flac"),("wav","pcm_s16le"),("aiff","pcm_s16be")] {
            let url = root.appendingPathComponent("roundtrip.\(ext)")
            _ = try run(["-v","error","-y","-f","lavfi","-i","sine=frequency=440:duration=0.3","-c:a",codec,"-metadata","title=Original","-metadata","replaygain_track_gain=-6.00 dB","-metadata","custom_keep=Preserve me",url.path])
            let before = try audioHash(url)
            try check(try TagEngine.read(from:url).title == "Original","\(ext): source title read failed")
            try TagEngine.write(updated,to:url)
            let restored = try TagEngine.read(from:url)
            try check(restored == updated,"\(ext): Unicode/text/lyrics/artwork roundtrip differs: \(restored)")
            try check(try audioHash(url) == before,"\(ext): decoded audio changed")
            let external = try run(["-v","error","-show_entries","format_tags","-of","json",url.path],tool:"ffprobe")
            try check(external.contains("测试标题"),"\(ext): independent parser cannot see updated title")
            if ext == "mp3" || ext == "flac" { try check(external.contains("Preserve me") && external.contains("-6.00 dB"),"\(ext): custom/replaygain tags lost") }
            let afterFirst = try Data(contentsOf:url)
            try TagEngine.write(updated,to:url)
            try check(try Data(contentsOf:url) == afterFirst,"\(ext): repeat save differs")
            try TagEngine.write(AudioTags(),to:url)
            try check(try TagEngine.read(from:url) == AudioTags(),"\(ext): clearing tags failed")
            try check(try audioHash(url) == before,"\(ext): clearing tags changed audio")
            let emptyExternal = try run(["-v","error","-show_entries","format_tags","-of","json",url.path],tool:"ffprobe")
            try check(!emptyExternal.contains("Original") && !emptyExternal.contains("测试标题"),"\(ext): independent parser sees stale tags")
            print("PASS \(ext): all fields, cover, lyrics, clearing, repeat save, audio SHA-256")
        }
        for version in [3,4] {
            let url = root.appendingPathComponent("id3-v2.\(version).mp3")
            _ = try run(["-v","error","-y","-f","lavfi","-i","sine=frequency=400:duration=0.2","-c:a","libmp3lame","-id3v2_version",String(version),"-metadata","title=Original","-metadata","custom_keep=Preserve me",url.path])
            let hash = try audioHash(url)
            try TagEngine.write(updated,to:url)
            try check(try TagEngine.read(from:url) == updated,"ID3v2.\(version) roundtrip differs")
            try check(try Data(contentsOf:url)[3] == UInt8(version),"ID3 version changed")
            try check(try audioHash(url) == hash,"ID3v2.\(version) audio changed")
            let external = try run(["-v","error","-show_entries","format_tags","-of","json",url.path],tool:"ffprobe")
            try check(external.contains("Preserve me"),"ID3v2.\(version) unknown tag lost")
            print("PASS ID3v2.\(version): version + unknown frame preserved")
        }
        // Safely refuse corrupt structures before replacing the original.
        for ext in ["mp3","flac","wav","aiff"] {
            let url = root.appendingPathComponent("malformed.\(ext)"); let bytes = Data("ID3\u{04}\u{00}\u{00}\u{7f}\u{7f}\u{7f}\u{7f}broken".utf8); try bytes.write(to:url)
            do { try TagEngine.write(updated,to:url); throw NSError(domain:"TagTests",code:2,userInfo:[NSLocalizedDescriptionKey:"accepted malformed \(ext)"]) } catch let e as TagError { _ = e }
            try check(try Data(contentsOf:url) == bytes,"\(ext): malformed input changed")
        }
        print("PASS malformed input: originals preserved")
    }
}
