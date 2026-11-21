import AppKit
import Foundation

@main struct OnlineLookupTests {
    static func main() async throws {
        setbuf(stdout, nil)
        var failures: [String] = []
        for source in [LookupSource.qq, .netease, .kugou, .itunes] {
            do {
                let query = source == .qq || source == .kugou ? "周杰伦 晴天" : source == .netease ? "陈奕迅 十年" : "The Beatles Yesterday"
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
                if source.hasSongLyrics {
                    let lyrics = try await OnlineLookup.lyrics(for: song)
                    guard lyrics.contains("[") && lyrics.count > 100 else { throw AppError.message("No usable synchronized lyrics") }
                    print("PASS \(source.name): LRC lyrics (\(lyrics.count) characters)")
                }
            } catch { failures.append("\(source.name): \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        }
        do {
            let query = "糖妹/安崎/炎明熹 我的骄傲 (Live)"
            let aggregate = try await OnlineLookup.aggregate(query: query, sources: [.qq])
            guard aggregate.failedSources.isEmpty,
                  case .song(let match)? = aggregate.results.first(where: { $0.id == "qq:361250065" }),
                  match.trackName == "我的骄傲 (Live)", match.artistName == "糖妹/安崎/炎明熹",
                  match.collectionName == "声生不息 第10期" else {
                throw AppError.message("No exact live recording in QQ results")
            }
            let detail = try await OnlineLookup.details(match)
            let lyrics = try await OnlineLookup.lyrics(for: match)
            guard detail.trackNumber == 7, detail.discNumber == 1, lyrics.contains("["), lyrics.count > 100 else {
                throw AppError.message("Missing live track details or synchronized lyrics")
            }
            print("PASS QQ 音乐: live recording and all three artists returned by aggregate search; verified detail and lyric identity")
        } catch { failures.append("QQ 音乐现场版: \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        do {
            let lyrics = try await OnlineLookup.lyrics(query: "The Beatles Yesterday")
            guard lyrics.contains(where: { !$0.lyrics.isEmpty }) else { throw AppError.message("No usable lyrics") }
            print("PASS LRCLIB: HTTPS search and lyric decoding (\(lyrics.count) results)")
        } catch { failures.append("LRCLIB: \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        do {
            let songs = try await OnlineLookup.songs(query: "Adele Hello", source: .kugou)
            guard let song = songs.first(where: { $0.trackName == "Hello" && $0.artistName == "Adele" && $0.kugouHash != nil }) else {
                throw AppError.message("No exact Adele / Hello catalogue match")
            }
            var options = LyricOptions()
            options.separator = " | "
            let lyrics = try await OnlineLookup.lyrics(for: song, options: options)
            let aligned = lyrics.split(separator: "\n").filter { row in
                guard row.range(of: #"^\[\d+:\d{2}\.\d{2}\]"#, options: .regularExpression) != nil,
                      let separator = row.range(of: " | ") else { return false }
                return row[..<separator.lowerBound].range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
                    && row[separator.upperBound...].range(of: #"\p{Han}"#, options: .regularExpression) != nil
            }
            guard aligned.count >= 10 else { throw AppError.message("No aligned English / Chinese lyrics") }
            print("PASS 酷狗音乐: Adele / Hello has \(aligned.count) aligned English / Chinese lines")
        } catch { failures.append("酷狗音乐双语歌词: \(error.localizedDescription)"); print("FAIL \(failures.last!)") }
        if !failures.isEmpty { exit(1) }
    }
}
