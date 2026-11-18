import Foundation
import CommonCrypto
import ImageIO
import Security

enum LookupSource: String, CaseIterable, Identifiable {
    case qq, netease, itunes, lrclib
    var id: String { rawValue }
    var name: String {
        switch self { case .qq: return "QQ 音乐"; case .netease: return "网易云音乐"; case .itunes: return "iTunes"; case .lrclib: return "LRCLIB" }
    }
    var website: URL {
        URL(string: self == .qq ? "https://y.qq.com" : self == .netease ? "https://music.163.com" : self == .itunes ? "https://music.apple.com" : "https://lrclib.net")!
    }
}

struct CatalogSong: Identifiable {
    let source: LookupSource
    let trackId: Int
    var trackName: String?
    var artistName: String?
    var collectionName: String?
    var primaryGenreName: String?
    var releaseDate: String?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var artworkUrl100: String?
    var trackViewUrl: String?
    var songMid: String?
    var duration: Double?
    var id: String { "\(source.rawValue):\(trackId)" }
    var artworkURL: URL? { OnlineLookup.httpsURL(artworkUrl100) }
    func applying(to tags: inout AudioTags) {
        if let v = trackName, !v.isEmpty { tags.title = v }
        if let v = artistName, !v.isEmpty { tags.artist = v }
        if let v = collectionName, !v.isEmpty { tags.album = v }
        if let v = primaryGenreName, !v.isEmpty { tags.genre = v }
        if let v = releaseDate, v.count >= 4 { tags.year = String(v.prefix(4)) }
        if let v = trackNumber, v > 0 { tags.track = "\(v)" + (trackCount.map { "/\($0)" } ?? "") }
        if let v = discNumber, v > 0 { tags.disc = "\(v)" + (discCount.map { "/\($0)" } ?? "") }
    }
}

struct BatchLookupResult {
    let song: CatalogSong
    let artwork: Data?
    let lyrics: String?

    func applying(to tags: inout AudioTags) {
        song.applying(to: &tags)
        if let artwork { tags.artwork = artwork }
        if let lyrics { tags.lyrics = lyrics }
    }
}

struct LyricResult: Decodable, Identifiable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
    var lyrics: String { syncedLyrics.flatMap { $0.isEmpty ? nil : $0 } ?? plainLyrics ?? "" }
}

/// Native implementation of MusicTag.exe's QQ / NetEase providers; no Windows runtime.
enum OnlineLookup {
    typealias Object = [String: Any]
    static func songs(query: String, country: String = "CN", source: LookupSource = .itunes, session: URLSession = .shared) async throws -> [CatalogSong] {
        switch source {
        case .qq:
            let param: Object = ["search_type": 0, "query": query, "page_num": 1, "num_per_page": 20]
            let search: Object = ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService", "param": param]
            let payload: Object = ["req_0": search]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let request = request(url("https://u.y.qq.com/cgi-bin/musicu.fcg", ["data": String(decoding: data, as: UTF8.self)]), source: source)
            do { return try parseSongs(await fetch(request, session: session), source: source) }
            catch {
                try Task.checkCancellation()
                // The shipped desktop endpoint can reject current clients with 2001.
                // Keep a second public QQ endpoint with the same song/album identities.
                let fallback = self.request(url("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", ["w": query, "p": "1", "n": "20", "format": "json"]), source: source)
                return try parseSongs(await fetch(fallback, session: session), source: source)
            }
        case .netease:
            let request = try neteaseRequest(path: "/weapi/cloudsearch/pc", payload: ["s": query, "type": 1, "limit": 25, "total": true, "offset": 0, "csrf_token": ""])
            return try parseSongs(await fetch(request, session: session), source: source)
        case .itunes:
            let endpoint = url("https://itunes.apple.com/search", ["term": query, "entity": "song", "media": "music", "country": country, "limit": "25"])
            return try parseSongs(await fetch(request(endpoint, source: source), session: session), source: source)
        case .lrclib: return []
        }
    }

    static func details(_ song: CatalogSong, session: URLSession = .shared) async throws -> CatalogSong {
        guard song.source == .netease else { return song }
        let c = String(decoding: try JSONSerialization.data(withJSONObject: [["id": song.trackId, "v": 0]], options: [.sortedKeys]), as: UTF8.self)
        let request = try neteaseRequest(path: "/weapi/v3/song/detail", payload: ["c": c, "csrf_token": ""])
        let rows = try parseSongs(await fetch(request, session: session), source: .netease)
        guard let detail = rows.first(where: { $0.trackId == song.trackId }) else { throw AppError.message("网易云音乐未返回这首歌的详情") }
        return detail
    }

    static func lyrics(query: String, session: URLSession = .shared) async throws -> [LyricResult] {
        try JSONDecoder().decode([LyricResult].self, from: await fetch(request(url("https://lrclib.net/api/search", ["q": query]), source: .lrclib), session: session))
    }

    static func lyrics(for song: CatalogSong, session: URLSession = .shared) async throws -> String {
        let endpoint: URL
        switch song.source {
        case .qq:
            guard let mid = song.songMid, !mid.isEmpty else { throw AppError.message("QQ 音乐结果缺少歌曲编号") }
            endpoint = url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", ["songmid": mid, "g_tk": "5381", "format": "json"])
        case .netease:
            endpoint = url("https://music.163.com/api/song/lyric", ["os": "pc", "id": String(song.trackId), "lv": "-1", "kv": "-1", "tv": "-1"])
        default: throw AppError.message("请选择 QQ 音乐、网易云音乐或 LRCLIB 查询歌词")
        }
        return try parseLyrics(await fetch(request(endpoint, source: song.source), session: session), source: song.source)
    }

    static func batchResult(for track: TrackItem, source: LookupSource, session: URLSession = .shared) async throws -> BatchLookupResult {
        let filename = track.filenameTags
        let title = track.tags.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.tags.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupTitle = title.isEmpty ? filename.title : title
        let lookupArtist = artist.isEmpty ? (filename.artist ?? "") : artist
        let titleKey = normalized(lookupTitle)
        let artistKey = artistNames(lookupArtist)
        guard !titleKey.isEmpty, !artistKey.isEmpty else {
            throw AppError.message("缺少标题或艺术家")
        }

        let songs = try await songs(query: "\(lookupArtist) \(lookupTitle)", source: source, session: session)
        let matches = songs.filter {
            normalized($0.trackName ?? "") == titleKey && artistNames($0.artistName ?? "") == artistKey
        }
        let durationMatches = matches.filter { song in
            guard track.duration.isFinite, track.duration > 0, let duration = song.duration else { return true }
            return abs(track.duration - duration) <= 4
        }
        let album = normalized(track.tags.album)
        let albumMatches = durationMatches.filter { !album.isEmpty && normalized($0.collectionName ?? "") == album }
        let candidates = albumMatches.isEmpty ? durationMatches : albumMatches
        guard candidates.count == 1, let song = candidates.first else {
            throw AppError.message(candidates.isEmpty ? "没有可靠匹配" : "找到多个匹配版本")
        }

        let detail = (try? await details(song, session: session)) ?? song
        try Task.checkCancellation()
        async let cover = batchArtwork(detail.artworkURL ?? song.artworkURL, format: track.format, session: session)
        async let lyricText = try? lyrics(for: song, session: session)
        let result = await BatchLookupResult(song: detail, artwork: cover, lyrics: lyricText)
        try Task.checkCancellation()
        return result
    }

    private static func batchArtwork(_ url: URL?, format: String, session: URLSession) async -> Data? {
        guard let url, let data = try? await fetch(url, session: session),
              format != "FLAC" || data.count <= 0xffffff - 128,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { return nil }
        return data
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func artistNames(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet(charactersIn: "/,，、;；"))
            .map(normalized).filter { !$0.isEmpty })
    }

    static func parseSongs(_ data: Data, source: LookupSource) throws -> [CatalogSong] {
        let root = try object(data)
        try checkCode(root, source: source)
        let rows: [Object]
        switch source {
        case .qq:
            if let req = root["req_0"] as? Object {
                try checkCode(req, source: source)
                guard let payload = req["data"] as? Object, let body = payload["body"] as? Object, let song = body["song"] as? Object, let list = song["list"] as? [Object] else { throw invalid(source) }
                rows = list
            } else {
                guard let payload = root["data"] as? Object, let song = payload["song"] as? Object, let list = song["list"] as? [Object] else { throw invalid(source) }
                rows = list.map { legacy in
                    var song = legacy
                    song["id"] = legacy["songid"]; song["mid"] = legacy["songmid"]; song["name"] = legacy["songname"]
                    song["album"] = ["name": legacy["albumname"] ?? "", "mid": legacy["albummid"] ?? ""]
                    song["index_album"] = legacy["cdIdx"]; song["index_cd"] = legacy["belongCD"]
                    if let timestamp = (legacy["pubtime"] as? NSNumber)?.doubleValue, timestamp > 0 { song["time_public"] = date(timestamp) }
                    return song
                }
            }
        case .netease:
            if let songs = root["songs"] as? [Object] { rows = songs }
            else if let result = root["result"] as? Object {
                if let songs = result["songs"] as? [Object] { rows = songs }
                else if integer(result["songCount"]) == 0 { rows = [] }
                else { throw invalid(source) }
            } else { throw invalid(source) }
        case .itunes:
            guard let results = root["results"] as? [Object] else { throw invalid(source) }
            rows = results
        case .lrclib: rows = []
        }
        var seen = Set<Int>()
        return rows.compactMap { row in
            guard let id = integer(row[source == .itunes ? "trackId" : "id"]), id > 0, seen.insert(id).inserted else { return nil }
            var song = CatalogSong(source: source, trackId: id)
            switch source {
            case .qq:
                let album = row["album"] as? Object ?? [:]
                song.trackName = string(row["title"]) ?? string(row["name"])
                song.artistName = names(row["singer"])
                song.collectionName = string(album["title"]) ?? string(album["name"])
                song.duration = positive(row["interval"]).map(Double.init)
                song.releaseDate = string(row["time_public"])
                song.trackNumber = positive(row["index_album"])
                // QQ's index_cd is zero based (0 is the first disc).
                song.discNumber = integer(row["index_cd"]).flatMap { $0 >= 0 ? $0 + 1 : nil }
                let genres = ["Pop", "Classical", "Jazz", "Rock", "Electronic", "Latin", "Easy Listening", "New Age", "World Music", "Rap", "Soundtrack", "Country", "Dance", "R&B", "Folk", "Metal", "Blues", "Alternative", "Religious"]
                if let genre = integer(row["genre"]), (1...genres.count).contains(genre) { song.primaryGenreName = genres[genre - 1] }
                if let mid = string(album["mid"]) { song.artworkUrl100 = "https://y.qq.com/music/photo_new/T002R800x800M000\(mid).jpg" }
                song.songMid = string(row["mid"])
                if let mid = song.songMid { song.trackViewUrl = "https://y.qq.com/n/ryqq/songDetail/\(mid)" }
            case .netease:
                let album = row["al"] as? Object ?? row["album"] as? Object ?? [:]
                song.trackName = string(row["name"])
                song.artistName = names(row["ar"] ?? row["artists"])
                song.collectionName = string(album["name"])
                song.duration = (positive(row["dt"]) ?? positive(row["duration"])).map { Double($0) / 1000 }
                song.artworkUrl100 = httpsURL(string(album["picUrl"]))?.absoluteString
                song.trackNumber = positive(row["no"])
                song.discNumber = string(row["cd"]).flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }.flatMap { $0 > 0 ? $0 : nil }
                let timestamp = (row["publishTime"] as? NSNumber)?.doubleValue ?? (album["publishTime"] as? NSNumber)?.doubleValue ?? 0
                if timestamp > 0 { song.releaseDate = date(timestamp / 1000) }
                song.trackViewUrl = "https://music.163.com/#/song?id=\(id)"
            case .itunes:
                song.trackName = string(row["trackName"]); song.artistName = string(row["artistName"]); song.collectionName = string(row["collectionName"])
                song.duration = positive(row["trackTimeMillis"]).map { Double($0) / 1000 }
                song.primaryGenreName = string(row["primaryGenreName"]); song.releaseDate = string(row["releaseDate"])
                song.trackNumber = positive(row["trackNumber"]); song.trackCount = positive(row["trackCount"])
                song.discNumber = positive(row["discNumber"]); song.discCount = positive(row["discCount"])
                song.artworkUrl100 = httpsURL(string(row["artworkUrl100"]))?.absoluteString; song.trackViewUrl = string(row["trackViewUrl"])
            case .lrclib: break
            }
            return song
        }
    }

    static func parseLyrics(_ data: Data, source: LookupSource) throws -> String {
        let root = try object(data)
        try checkCode(root, source: source)
        let original: String, translation: String
        if source == .qq {
            func decoded(_ value: Any?) -> String {
                guard let raw = string(value) else { return "" }
                if let bytes = Data(base64Encoded: raw), let text = String(data: bytes, encoding: .utf8) { return unescape(text) }
                return unescape(raw)
            }
            original = decoded(root["lyric"]); translation = decoded(root["trans"])
        } else {
            original = string((root["lrc"] as? Object)?["lyric"]) ?? ""
            translation = string((root["tlyric"] as? Object)?["lyric"]) ?? ""
        }
        let result = [original, translation == original ? "" : translation].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        guard !result.isEmpty, !result.contains("此歌曲为没有填词的纯音乐") else { throw AppError.message("\(source.name)暂无可用歌词（可能为纯音乐）") }
        return result
    }

    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Data { try await fetch(request(url, source: nil), session: session) }
    static func fetch(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        guard request.url?.scheme == "https" else { throw AppError.message("仅支持 HTTPS 来源") }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.scheme == "https" else { throw AppError.message("来源服务暂时不可用，请稍后重试") }
        guard data.count <= 30 * 1024 * 1024 else { throw AppError.message("返回内容过大") }
        return data
    }
    static func request(_ url: URL, source: LookupSource?) -> URLRequest {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if source == .qq { request.setValue("Mozilla/5.0 (Windows NT 6.3; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.106 Safari/537.36", forHTTPHeaderField: "User-Agent"); request.setValue("https://i.y.qq.com/", forHTTPHeaderField: "Referer"); request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language") }
        if source == .netease { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        return request
    }
    static func neteaseRequest(path: String, payload: Object) throws -> URLRequest {
        var request = request(URL(string: "https://music.163.com\(path)")!, source: .netease)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NetEaseCrypto.form(payload)
        return request
    }
    static func url(_ endpoint: String, _ query: [String: String]) -> URL {
        var parts = URLComponents(string: endpoint)!
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        parts.percentEncodedQuery = query.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        return parts.url!
    }
    static func httpsURL(_ raw: String?) -> URL? {
        guard let raw = raw else { return nil }
        let value = raw.hasPrefix("//") ? "https:" + raw : raw.replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static func object(_ data: Data) throws -> Object {
        guard let text = String(data: data, encoding: .utf8) else { throw AppError.message("来源返回了无效文本") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Legacy QQ replies may be JSONP; only parse the wrapper, never evaluate it.
        let json: String
        if trimmed.hasPrefix("{") { json = trimmed }
        else if let first = trimmed.firstIndex(of: "("), let last = trimmed.lastIndex(of: ")"), first < last { json = String(trimmed[trimmed.index(after: first)..<last]) }
        else { throw AppError.message("来源返回了无效数据，请稍后重试") }
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Object else { throw AppError.message("来源返回了无效数据") }
        return object
    }
    static func checkCode(_ root: Object, source: LookupSource) throws {
        for key in ["code", "retcode"] {
            if let code = integer(root[key]), code != 0 && !(source == .netease && code == 200) {
                throw AppError.message("\(source.name)请求失败（\(code)），请稍后重试")
            }
        }
    }
    static func invalid(_ source: LookupSource) -> AppError { .message("\(source.name)返回的数据格式已变化，请稍后重试") }
    static func integer(_ value: Any?) -> Int? { if let n = value as? NSNumber { return n.intValue }; if let s = value as? String { return Int(s) }; return nil }
    static func positive(_ value: Any?) -> Int? { integer(value).flatMap { $0 > 0 ? $0 : nil } }
    static func string(_ value: Any?) -> String? { guard let s = value as? String, !s.isEmpty, s != "null" else { return nil }; return unescape(s) }
    static func date(_ timestamp: Double) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    static func names(_ value: Any?) -> String? { let result = (value as? [Object] ?? []).compactMap { string($0["name"]) }.joined(separator: "/"); return result.isEmpty ? nil : result }
    static func unescape(_ value: String) -> String {
        var result = value
        let replacements = ["&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: result), let whole = Range(match.range, in: result) else { continue }
                let digits = String(result[digitsRange]); let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number = number, let scalar = UnicodeScalar(number) { result.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// WEAPI: Base64(AES-CBC(Base64(AES-CBC(JSON)))) plus raw RSA of reversed session key.
/// Constants and ordering recovered from MusicTag.dll rc2 / FUN_10062c80.
enum NetEaseCrypto {
    static let modulus = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
    static func form(_ payload: [String: Any], secret: String? = nil) throws -> Data {
        let secret = secret ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        guard secret.utf8.count == 16 else { throw AppError.message("请求加密密钥长度错误") }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let first = try aes(json, key: "0CoJUm6Qyw8W8jud").base64EncodedString()
        let params = try aes(Data(first.utf8), key: secret).base64EncodedString()
        let encSecKey = try rsa(secret)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data("params=\(params.addingPercentEncoding(withAllowedCharacters: allowed)!)&encSecKey=\(encSecKey)".utf8)
    }
    static func aes(_ data: Data, key: String) throws -> Data {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128); var length = 0
        let status = data.withUnsafeBytes { bytes in
            Array(key.utf8).withUnsafeBytes { keyBytes in
                Array("0102030405060708".utf8).withUnsafeBytes { iv in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, kCCKeySizeAES128, iv.baseAddress, bytes.baseAddress, data.count, &output, output.count, &length)
                }
            }
        }
        guard status == kCCSuccess else { throw AppError.message("网易云请求加密失败") }
        return Data(output.prefix(length))
    }
    static func rsa(_ secret: String) throws -> String {
        let bytes = stride(from: 0, to: modulus.count, by: 2).map { offset -> UInt8 in
            let start = modulus.index(modulus.startIndex, offsetBy: offset)
            return UInt8(modulus[start..<modulus.index(start, offsetBy: 2)], radix: 16)!
        }
        // PKCS#1 RSAPublicKey, positive 1024-bit modulus and exponent 65537.
        let der = Data([0x30, 0x81, 0x89, 0x02, 0x81, 0x81, 0x00] + bytes + [0x02, 0x03, 0x01, 0x00, 0x01])
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 1024]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else { throw AppError.message("网易云请求公钥初始化失败") }
        let message = Data(repeating: 0, count: 128 - secret.utf8.count) + Data(secret.utf8.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, message as CFData, &error) as Data? else { throw AppError.message("网易云请求密钥加密失败") }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }
}
