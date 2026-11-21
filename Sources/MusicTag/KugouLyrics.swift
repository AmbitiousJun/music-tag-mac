import Foundation
import zlib

enum KugouLyrics {
    typealias Lyrics = (original: String, translation: String?)

    private static let service = "https://lyrics.kugou.com"
    private static let maximumContentSize = 512 * 1024
    private static let maximumTextSize = 2 * 1024 * 1024

    static func fetch(
        title: String, artist: String, hash: String?, duration: Int?, includeTranslation: Bool,
        session: URLSession = .shared
    ) async throws -> Lyrics? {
        let titleKey = matchKey(title)
        let artistKey = matchKey(artist)
        guard !titleKey.isEmpty, !artistKey.isEmpty else { return nil }

        var query = ["keyword": "\(artist) - \(title)", "ver": "1", "man": "yes"]
        if let hash, !hash.isEmpty { query["hash"] = hash }
        let durationMS = duration.flatMap { (1...86_400).contains($0) ? $0 * 1_000 : nil }
        if let durationMS { query["duration"] = String(durationMS) }
        let data = try await OnlineLookup.fetch(OnlineLookup.url(service + "/search", query), session: session)
        let response = try OnlineLookup.object(data)
        guard OnlineLookup.integer(response["status"]) == 200,
              let rows = response["candidates"] as? [OnlineLookup.Object] else {
            throw AppError.message("酷狗音乐歌词搜索暂时不可用")
        }

        let candidates = rows.filter { row in
            guard let song = OnlineLookup.string(row["song"]), matchKey(song) == titleKey,
                  let singer = OnlineLookup.string(row["singer"]), matchKey(singer) == artistKey else { return false }
            guard let durationMS, let candidateMS = OnlineLookup.integer(row["duration"]), candidateMS > 0 else { return true }
            return (durationMS - 4_000...durationMS + 4_000).contains(candidateMS)
        }

        var fallback: Lyrics?
        var lastError: Error?
        for format in includeTranslation ? ["krc", "lrc"] : ["lrc"] {
            for row in candidates.prefix(4) {
                guard let id = OnlineLookup.string(row["id"]), let accessKey = OnlineLookup.string(row["accesskey"]) else { continue }
                let url = OnlineLookup.url(service + "/download", ["ver": "1", "id": id, "accesskey": accessKey, "fmt": format])
                do {
                    let response = try OnlineLookup.object(await OnlineLookup.fetch(url, session: session))
                    guard OnlineLookup.integer(response["status"]) == 200,
                          let content = response["content"] as? String, content.utf8.count <= maximumContentSize,
                          let bytes = Data(base64Encoded: content) else { continue }
                    let lyrics = format == "krc"
                        ? decodeKRC(bytes)
                        : String(data: bytes, encoding: .utf8).map { ($0, nil) }
                    guard let lyrics, LyricFormatter.hasContent(lyrics.original) else { continue }
                    if format == "lrc" || lyrics.translation != nil { return lyrics }
                    if fallback == nil { fallback = lyrics }
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                }
            }
            if let fallback { return fallback }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func matchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    // KRC's public file format uses a fixed mask on a zlib stream after the krc1 header.
    private static let krcMask: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
    private static let rowPattern = try! NSRegularExpression(pattern: #"^\[([0-9]+),[0-9]+\]"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"<[0-9]+,[0-9]+,[0-9]+>"#)

    static func decodeKRC(_ data: Data) -> Lyrics? {
        guard data.count > 4, data.count <= maximumContentSize, data.starts(with: "krc1".utf8) else { return nil }
        let compressed = data.dropFirst(4).enumerated().map { index, byte in byte ^ krcMask[index % krcMask.count] }
        var textSize = uLongf(maximumTextSize)
        var plain = [UInt8](repeating: 0, count: maximumTextSize)
        guard uncompress(&plain, &textSize, compressed, uLong(compressed.count)) == Z_OK,
              let text = String(bytes: plain.prefix(Int(textSize)), encoding: .utf8) else { return nil }
        return parseKRC(text)
    }

    private static func parseKRC(_ text: String) -> Lyrics? {
        var metadata: [String] = []
        var labeledTranslation: [String]?
        var rows: [(tag: String, text: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            let range = NSRange(row.startIndex..., in: row)
            if let match = rowPattern.firstMatch(in: row, range: range),
               let timing = Range(match.range(at: 1), in: row),
               let start = Int(row[timing]), let tag = Range(match.range, in: row) {
                let contents = String(row[tag.upperBound...])
                let contentRange = NSRange(contents.startIndex..., in: contents)
                let words = wordPattern.stringByReplacingMatches(in: contents, range: contentRange, withTemplate: "")
                let time = String(format: "[%02lld:%02lld.%03lld]", Int64(start / 60_000), Int64(start / 1_000 % 60), Int64(start % 1_000))
                rows.append((time, words))
            } else if row.hasPrefix("[language:"), row.hasSuffix("]") {
                labeledTranslation = translationLayer(String(row.dropFirst("[language:".count).dropLast()))
            } else if ["[ti:", "[ar:", "[al:", "[by:", "[offset:"].contains(where: { row.hasPrefix($0) }), row.hasSuffix("]") {
                metadata.append(row)
            }
        }
        guard !rows.isEmpty else { return nil }
        let original = (metadata + rows.map { $0.tag + $0.text }).joined(separator: "\n")
        // The translation has no timestamps. Its ordinals are usable only if its row count agrees.
        guard let labeledTranslation, labeledTranslation.count == rows.count else { return (original, nil) }
        let translatedRows = zip(rows, labeledTranslation).compactMap { row, translation in
            translation.isEmpty ? nil : row.tag + translation
        }
        guard !translatedRows.isEmpty else { return (original, nil) }
        return (original, (metadata + translatedRows).joined(separator: "\n"))
    }

    private static func translationLayer(_ encoded: String) -> [String]? {
        guard let bytes = Data(base64Encoded: encoded),
              let document = try? OnlineLookup.object(bytes),
              let content = document["content"] as? [OnlineLookup.Object],
              let translation = content.first(where: { OnlineLookup.integer($0["type"]) == 1 }),
              let rows = translation["lyricContent"] as? [Any] else { return nil }
        return rows.map { row in
            let text = (row as? [String])?.joined() ?? row as? String ?? ""
            // Keep each provider row aligned to a single synced lyric line.
            return text.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
