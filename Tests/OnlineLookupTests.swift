import AppKit
import Foundation

@main struct OnlineLookupTests {
    static func main() async throws {
        setbuf(stdout, nil)
        var failures: [String] = []
        for source in [LookupSource.qq, .netease, .itunes] {
            do {
                let query = source == .qq ? "周杰伦 晴天" : source == .netease ? "陈奕迅 十年" : "The Beatles Yesterday"
                let songs = try await OnlineLookup.songs(query: query, country: "US", source: source)
                guard let first = songs.first else { throw AppError.message("No search results") }
                print("PASS \(source.name): HTTPS search (\(songs.count) results), first: \(first.trackName ?? "") / \(first.artistName ?? "")")
                let song = try await OnlineLookup.details(first)
                guard song.trackId == first.trackId, song.artistName != nil, song.collectionName != nil else { throw AppError.message("Incomplete song details") }
                print("PASS \(source.name): details, date=\(song.releaseDate ?? "unavailable"), track=\(song.trackNumber.map(String.init) ?? "unavailable")")
                guard let url = song.artworkURL else { throw AppError.message("Missing artwork") }
                let image = try await OnlineLookup.fetch(url)
                guard NSImage(data: image) != nil else { throw AppError.message("Invalid artwork") }
                print("PASS \(source.name): HTTPS cover / native image decoding (\(image.count) bytes)")
                if source == .qq || source == .netease {
                    let lyrics = try await OnlineLookup.lyrics(for: song)
                    guard lyrics.contains("[") && lyrics.count > 100 else { throw AppError.message("No usable synchronized lyrics") }
                    print("PASS \(source.name): LRC lyrics (\(lyrics.count) characters)")
                }
            } catch { failures.append("\(source.name): \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        }
        do {
            let lyrics = try await OnlineLookup.lyrics(query: "The Beatles Yesterday")
            guard lyrics.contains(where: { !$0.lyrics.isEmpty }) else { throw AppError.message("No usable lyrics") }
            print("PASS LRCLIB: HTTPS search and lyric decoding (\(lyrics.count) results)")
        } catch { failures.append("LRCLIB: \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        if !failures.isEmpty { exit(1) }
    }
}
