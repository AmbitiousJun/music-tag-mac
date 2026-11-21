import Foundation

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw AppError.message(message) }
}
private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct LookupProviderTests {
    static func main() async throws {
        let qqFixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("qq-search.json"))
        let qq = try OnlineLookup.parseSongs(qqFixture, source: .qq)[0]
        try expect(qq.trackName == "晴天" && qq.artistName == "周杰伦" && qq.collectionName == "叶惠美", "QQ mapping")
        try expect(qq.trackNumber == 3 && qq.discNumber == 1 && qq.releaseDate == "2003-07-31", "QQ numbers/date")
        try expect(qq.primaryGenreName == "Pop" && qq.artworkURL?.scheme == "https", "QQ genre/artwork")
        print("PASS QQ real search fixture: names, genre, date, track, zero-based disc, cover")
        let detailSong: [String: Any] = ["id": 123, "name": "十年", "ar": [["name": "陈奕迅"], ["name": "合唱"]], "al": ["name": "黑白灰", "picUrl": "http://p1.music.126.net/test.jpg"], "publishTime": 1052496000000, "no": 7, "cd": "2/3"]
        let detail: [String: Any] = ["code": 200, "songs": [detailSong]]
        let netease = try OnlineLookup.parseSongs(json(detail), source: .netease)[0]
        try expect(netease.artistName == "陈奕迅/合唱" && netease.trackNumber == 7 && netease.discNumber == 2 && netease.releaseDate?.hasPrefix("2003") == true && netease.artworkURL?.scheme == "https", "NetEase mapping")
        var tags = AudioTags(); tags.composer = "保留作曲"; tags.genre = "保留流派"; tags.track = "9/12"; tags.disc = "1"
        netease.applying(to: &tags)
        try expect(tags.title == "十年" && tags.genre == "保留流派" && tags.composer == "保留作曲" && tags.track == "7" && tags.disc == "2", "non-empty tag application")
        try expect(qq.id != CatalogSong(source: .netease, trackId: qq.trackId).id, "source-qualified identity")
        print("PASS NetEase detail fixture and tag application preserve unavailable fields")
        let lrc = "[00:01.00]晴天 & 你好"
        let encoded = try json(["code": 0, "lyric": Data(lrc.utf8).base64EncodedString(), "trans": Data("[00:01.00]Hello".utf8).base64EncodedString()])
        let decoded = try OnlineLookup.parseLyrics(encoded, source: .qq)
        try expect(decoded == lrc + " Hello", "QQ Base64 and default bilingual layout")
        var options = LyricOptions()
        options.layout = .sections
        try expect(try OnlineLookup.parseLyrics(encoded, source: .qq, options: options) == lrc + "\n[00:01.00]Hello", "QQ compatibility layout")
        options.translationEnabled = false
        options.removeTimes = true
        try expect(try OnlineLookup.parseLyrics(encoded, source: .qq, options: options) == "晴天 & 你好", "QQ applies shared cleanup and translation options")
        let wrapped = Data("MusicJsonCallback(\(String(decoding: try json(["code": 0, "lyric": "[00:01.00]A &#38; B &quot;C&quot;"]), as: UTF8.self)));".utf8)
        try expect(try OnlineLookup.parseLyrics(wrapped, source: .qq) == "[00:01.00]A & B \"C\"", "QQ JSONP and entities")
        try expect(try OnlineLookup.parseLyrics(json(["code": 200, "lrc": ["lyric": lrc], "tlyric": ["lyric": "[00:01.00]译文"]]), source: .netease).contains("译文"), "NetEase lyrics")
        let lrclib = LyricResult(id: 1, trackName: "Lyrics", artistName: "Artist", albumName: nil, duration: nil, instrumental: false, plainLyrics: "Fallback", syncedLyrics: "[ti:Song]\n[00:01.00]")
        try expect(lrclib.formattedLyrics(options: options) == "Fallback", "LRCLIB uses usable plain lyrics when synced lyrics have no body")
        for (source, value) in [(LookupSource.qq, ["code": 0, "lyric": ""] as [String: Any]), (.netease, ["code": 200, "nolyric": true])] {
            do { _ = try OnlineLookup.parseLyrics(json(value), source: source); throw AppError.message("accepted empty lyric") }
            catch let error as AppError { try expect(error.localizedDescription.contains("暂无"), "empty lyric handling") }
        }
        print("PASS Base64 / JSONP / entity decoding, translations and missing lyrics")
        try testKugouLyrics()
        try expect(try OnlineLookup.parseSongs(json(["code": 200, "result": ["songCount": 0]]), source: .netease).isEmpty, "zero result")
        for value in [["code": 401], ["code": 200, "unexpected": 1]] {
            do { _ = try OnlineLookup.parseSongs(json(value), source: .netease); throw AppError.message("accepted service error") }
            catch let error as AppError { try expect(error.localizedDescription.contains("失败") || error.localizedDescription.contains("格式"), "service/schema error handling") }
        }
        let form = String(decoding: try NetEaseCrypto.form(["s": "十年", "type": 1], secret: "0123456789abcdef"), as: UTF8.self)
        let expectedAES = "DIVSWYtKqu1M8yOBNcTrdkb1VkKe6XuWk9wdSMc5bdb6UbOsuYu7UEzY+bn/vSY+"
        let expectedRSA = "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52"
        try expect(form.removingPercentEncoding == "params=\(expectedAES)&encSecKey=\(expectedRSA)", "WEAPI independent OpenSSL/Python vector")
        try expect(!form.contains("+"), "form encoding must escape Base64 plus")
        print("PASS WEAPI two AES-CBC stages / PKCS7 / Base64 / raw RSA against independent vector")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        try await testQQSearch(session: session, desktopSong: qq)
        StubProtocol.handler = { request in
            try expect(request.httpMethod == "POST" && request.url?.path == "/weapi/v3/song/detail" && request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "NetEase detail transport")
            return (200, try json(detail))
        }
        _ = try await OnlineLookup.details(netease, session: session)
        StubProtocol.handler = { _ in (503, Data()) }
        do { _ = try await OnlineLookup.fetch(URL(string: "https://example.com")!, session: session); throw AppError.message("accepted HTTP failure") }
        catch let error as AppError { try expect(error.localizedDescription.contains("不可用"), "HTTP errors") }
        do { _ = try await OnlineLookup.fetch(URL(string: "http://example.com")!, session: session); throw AppError.message("accepted HTTP source") }
        catch let error as AppError { try expect(error.localizedDescription.contains("HTTPS"), "HTTPS restriction") }
        print("PASS request headers, Unicode/special-character escaping, detail POST and transport errors")
        try await testBatchLookup(session: session)
        try await testKugouRequests(session: session)
        try await testAggregateLookup(session: session)
    }

    private static func testQQSearch(session: URLSession, desktopSong: CatalogSong) async throws {
        let liveQuery = "糖妹/安崎/炎明熹 我的骄傲 (Live)"
        let specialQuery = #"A"B\C & 中文+"#
        let liveRow: [String: Any] = [
            "songid": 361250065, "songmid": "0010BQDD2bOrMw", "songname": "我的骄傲 (Live)",
            "singer": ["糖妹", "安崎", "炎明熹"].map { ["name": $0] }, "albumname": "声生不息 第10期",
            "albummid": "000MA98a3K9N1h", "pubtime": 1656172800, "interval": 240
        ]
        let liveResponse = try json(["code": 0, "data": ["song": ["list": [liveRow]]]])
        let legacyFixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("qq-legacy-search.json"))
        StubProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            try expect(url.scheme == "https" && url.host == "c.y.qq.com"
                       && url.path == "/soso/fcgi-bin/search_for_qq_cp"
                       && request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Referer") == "https://i.y.qq.com/", "QQ H5 transport")
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let params = Dictionary(uniqueKeysWithValues: (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            try expect(params["p"] == "1" && params["n"] == "20" && params["format"] == "json", "QQ H5 result options")
            switch params["w"] {
            case liveQuery: return (200, liveResponse)
            case "周杰伦 晴天": return (200, legacyFixture)
            case specialQuery:
                try expect(parts?.percentEncodedQuery?.contains("%2B") == true, "QQ H5 encodes literal plus")
                return (200, legacyFixture)
            default: throw AppError.message("QQ H5 did not preserve the search query")
            }
        }
        let normal = try await OnlineLookup.songs(query: "周杰伦 晴天", source: .qq, session: session)
        try expect(normal.first?.trackId == desktopSong.trackId && normal.first?.artworkURL == desktopSong.artworkURL, "QQ uses stable song and album identities")
        let special = try await OnlineLookup.songs(query: specialQuery, source: .qq, session: session)
        try expect(special.count == 1, "QQ H5 special-character query")
        let liveResults = try await OnlineLookup.songs(query: liveQuery, source: .qq, session: session)
        guard let live = liveResults.first else { throw AppError.message("QQ live result missing") }
        try expect(live.trackId == 361250065 && live.songMid == "0010BQDD2bOrMw" && live.trackName == "我的骄傲 (Live)"
                   && live.artistName == "糖妹/安崎/炎明熹" && live.collectionName == "声生不息 第10期"
                   && live.artworkURL?.lastPathComponent == "T002R800x800M000000MA98a3K9N1h.jpg" && live.duration == 240,
                   "QQ H5 live track and album identities")
        let aggregated = try await OnlineLookup.aggregate(query: liveQuery, sources: [.qq], session: session)
        try expect(aggregated.results.first?.id == live.id && aggregated.failedSources.isEmpty, "QQ H5 live query works in aggregate mode")
        let trackInfo: [String: Any] = ["id": live.trackId, "mid": "0010BQDD2bOrMw", "genre": 1,
                                        "index_cd": 0, "index_album": 7, "time_public": "2022-06-26"]
        for valid in [true, false] {
            var row = trackInfo
            if !valid { row["mid"] = "unrelated-track" }
            let result: [String: Any] = ["code": 0, "data": ["track_info": row]]
            let detailResponse = try json(["code": 0, "req_0": result])
            StubProtocol.handler = { request in
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                let requestData = components?.queryItems?.first { $0.name == "data" }?.value ?? ""
                let root = try OnlineLookup.object(Data(requestData.utf8))
                let service = root["req_0"] as? [String: Any]
                let params = service?["param"] as? [String: Any]
                guard components?.host == "u.y.qq.com", service?["method"] as? String == "get_song_detail_yqq",
                      params?["song_id"] as? Int == live.trackId else {
                    throw AppError.message("Unexpected QQ detail request")
                }
                return (200, detailResponse)
            }
            let detail = try await OnlineLookup.details(live, session: session)
            try expect(detail.trackName == live.trackName && detail.artworkURL == live.artworkURL, "QQ details preserve the selected result")
            try expect(detail.trackNumber == (valid ? 7 : nil) && detail.discNumber == (valid ? 1 : nil)
                       && detail.primaryGenreName == (valid ? "Pop" : nil), "QQ details enrich matching results only")
        }
        print("PASS QQ H5 search: exact Live query, escaping, aggregate integration, song identity and detail enrichment")
    }

    private static func testAggregateLookup(session: URLSession) async throws {
        let qqRows: [[String: Any]] = [
            ["songid": 2, "songname": "周杰伦晴天现场版"],
            ["songid": 1, "songname": "晴天", "singer": [["name": "周杰伦"]]]
        ]
        let qq = try json(["code": 0, "data": ["song": ["list": qqRows]]])
        let kugou = try json(["status": 1, "error_code": 0, "data": ["lists": [OnlineLookup.Object]()]])
        let itunesRows: [OnlineLookup.Object] = [["trackId": 1, "trackName": "晴天", "artistName": "周杰伦"]]
        let itunes = try json(["results": itunesRows])
        let lrclibRows: [OnlineLookup.Object] = [
            ["id": 1, "trackName": "晴天", "artistName": "周杰伦", "plainLyrics": "歌词"],
            ["id": 1, "trackName": "晴天", "artistName": "周杰伦", "plainLyrics": "重复结果"]
        ]
        let lrclib = try JSONSerialization.data(withJSONObject: lrclibRows)
        StubProtocol.handler = { request in
            switch request.url?.host {
            case "c.y.qq.com": return (200, qq)
            case "music.163.com": return (503, Data())
            case "songsearch.kugou.com": return (200, kugou)
            case "itunes.apple.com": return (200, itunes)
            case "lrclib.net": return (200, lrclib)
            default: throw AppError.message("unexpected aggregate endpoint")
            }
        }
        for query in ["周杰伦 晴天", "晴天 周杰伦", "周杰伦晴天"] {
            let response = try await OnlineLookup.aggregate(query: query, sources: Set(LookupSource.allCases), session: session)
            try expect(response.results.map(\.id) == ["qq:1", "itunes:1", "lrclib:1", "qq:2"], "aggregate keyword ranking, stable order, qualified identity and duplicate handling")
            try expect(response.failedSources == [.netease], "failed sources distinguished from successful empty providers")
        }
        let response = try await OnlineLookup.aggregate(query: "晴天", sources: [.lrclib], session: session)
        try expect(response.results.map(\.id) == ["lrclib:1"] && response.failedSources.isEmpty, "aggregate uses selected sources")
        print("PASS aggregate ranking, stable provider order, mixed results, selected sources and partial failure")
    }

    private static func testKugouLyrics() throws {
        // Independently encoded synthetic KRC with a blank timed row and a 10 ms offset.
        let bilingual = Data(base64Encoded: "a3JjMTjbHPsfXfYHRbLe08Q9i5kA0HnVEyZRqTdlWhROwGHFbKP4mjTusdEu6TT+anVwN56LBZF1Zt3c51pVCfWkf2jBJCf3AJw5cWBuXPgZ48tIHWhs+sejTfxM1twMOlV8E898Pf7yUWkSMV5T3TlN/zw5qZWBcVGHSNJd9AQ8queNsOX/awXDDGI5raNiV2+xu96uNoIgg0zKW71grxFk0yIn6RQa+r8IN4sxMQLK6qOoS9vloFrdssm2i6gjT5BDLgWXZpmCVEZi8AFKQ6iR6/4udZUJXki2HCI=")!
        let mismatched = Data(base64Encoded: "a3JjMTjbHPuTOPYHRbPGE4vdjosqbURhqhW5ZxQzWGTFfycHTRRZ5LvpQ10QnSe6tRyPFWei+F9Aa7U7B+V6Q3Vi4TRg0DpmKRfqoa2P7j1Bnin7DO8FfuPdFBa0VPxefxBL57P/x0K/Ej1voM2+ZYGbzJy8MAKBORHONHuY5CP+CzQUjUlvMfTie7b0KBT+KKRQIuY7asPoMrSzUTgwtXhEXmXx08tkavQdRN+0KIQT1pRdkzI9uLJP7BkKvwOgem9ZV9EVIA==")!
        let originalOnly = Data(base64Encoded: "a3JjMTjb6lmXhgaM/R4YAIRfi+OOCCpcEB/FdWU2gyDD3mIdjEttFTM+AMvRejIWeR7Mi1JCemeZNljXwq+m59u/antAJcFpPSEndEw9uTPFYnz2BOd3x2QyMdlNXg==")!
        guard let lyrics = KugouLyrics.decodeKRC(bilingual) else { throw AppError.message("KRC bilingual fixture failed to decode") }
        let formatted = LyricFormatter.format(original: lyrics.original, translation: lyrics.translation, options: LyricOptions())
        try expect(formatted == "[ti:Fixture]\n[00:01.01]First line 甲句\n[00:02.21]\n[00:03.46]Last line 乙句", "KRC line times, word tags, translation ordinals and shared offset")
        for sample in [mismatched, originalOnly] {
            let result = KugouLyrics.decodeKRC(sample)
            try expect(result?.original == lyrics.original && result?.translation == nil, "KRC preserves original without an aligned translation")
        }
        for sample in [Data(), Data("bad!".utf8) + bilingual.dropFirst(4), Data(bilingual.prefix(10))] {
            try expect(KugouLyrics.decodeKRC(sample) == nil, "Malformed KRC rejected")
        }
        print("PASS Kugou KRC: aligned bilingual lyrics, offsets, missing and misaligned translation, invalid content")
    }

    @MainActor private static func testKugouRequests(session: URLSession) async throws {
        let primary: [String: Any] = ["ID": 31, "SongName": "Sample", "SingerName": "Artist", "AlbumName": "Album A", "Duration": 180]
        let related: [String: Any] = ["ID": 32, "SongName": "Sample", "SingerName": "Artist", "AlbumName": "Album B", "Duration": 180]
        var group = primary
        group["Grp"] = [primary, related]
        let search = try json(["status": 1, "error_code": 0, "data": ["lists": [group]]])
        StubProtocol.handler = { request in
            try expect(request.url?.host == "songsearch.kugou.com", "Ambiguous grouping must skip lyric and cover requests")
            return (200, search)
        }
        let tags = AudioTags(title: "Sample", artist: "Artist")
        let song = TrackItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/Artist - Sample.flac"), tags: tags, savedTags: tags,
                             duration: 180, size: 0, sampleRate: 0, channels: 0, issue: nil)
        do {
            _ = try await OnlineLookup.batchResult(for: song, source: .kugou, session: session)
            throw AppError.message("Accepted ambiguous grouped result")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("多个"), "Grouped search must preserve ambiguity when the local album is absent")
        }

        let original = "[00:01.00]Original"
        StubProtocol.handler = { request in
            guard let url = request.url,
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                throw AppError.message("Missing lyric request URL")
            }
            if url.path == "/search" {
                try expect(query.contains(URLQueryItem(name: "duration", value: "180000")), "Lyric search requests milliseconds")
                let candidates: [[String: Any]] = [
                    ["id": "other", "accesskey": "test", "song": "Sample", "singer": "Other", "duration": 180000],
                    ["id": "matched", "accesskey": "test", "song": "Sample", "singer": "Artist", "duration": 180000]
                ]
                return (200, try json(["status": 200, "candidates": candidates]))
            }
            try expect(url.path == "/download" && query.contains(URLQueryItem(name: "id", value: "matched")), "Lyric download uses only the matching candidate")
            let content = query.contains(URLQueryItem(name: "fmt", value: "krc")) ? "invalid" : Data(original.utf8).base64EncodedString()
            return (200, try json(["status": 200, "content": content]))
        }
        let lyric = try await KugouLyrics.fetch(title: "Sample", artist: "Artist", hash: nil, duration: 180,
                                                 includeTranslation: true, session: session)
        try expect(lyric?.original == original && lyric?.translation == nil, "Kugou preserves LRC when bilingual KRC is unavailable")
        print("PASS Kugou grouped catalogue ambiguity and original-only LRC fallback")

        func liveLyrics(candidateTitle: String, candidateArtist: String = "Artist A、Artist B",
                        candidateDuration: Int? = 180_065, hash: String? = "test-hash",
                        duration: Int? = 180, exactTitle: Bool = false) async throws -> String? {
            StubProtocol.handler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if url.path == "/search" {
                    try expect(params.first { $0.name == "hash" }?.value == hash, "Lyric search passes the recording hash")
                    var candidate: [String: Any] = ["id": "base", "accesskey": "test", "song": candidateTitle, "singer": candidateArtist]
                    candidate["duration"] = candidateDuration
                    let exact: [String: Any] = ["id": "exact", "accesskey": "test", "song": "Sample (Live)",
                                                 "singer": "Artist A、Artist B", "duration": 180_065]
                    return (200, try json(["status": 200, "candidates": exactTitle ? [candidate, exact] : [candidate]]))
                }
                let exact = params.contains(URLQueryItem(name: "id", value: "exact"))
                let content = Data("[00:01.00]\(exact ? "Exact" : "Base")".utf8).base64EncodedString()
                return (200, try json(["status": 200, "content": content]))
            }
            return try await KugouLyrics.fetch(title: "Sample （Live）", artist: "Artist A/Artist B", hash: hash,
                                               duration: duration, includeTranslation: false, session: session)?.original
        }

        let base = try await liveLyrics(candidateTitle: "Sample")
        let exact = try await liveLyrics(candidateTitle: "Sample", exactTitle: true)
        try expect(base == "[00:01.00]Base", "Hash-scoped live recordings accept the base lyric title")
        try expect(exact == "[00:01.00]Exact", "Prefer the exact lyric title when both titles are present")
        let rejected = [
            try await liveLyrics(candidateTitle: "Sample (Remix)"),
            try await liveLyrics(candidateTitle: "Sample", candidateArtist: "Artist B"),
            try await liveLyrics(candidateTitle: "Sample", candidateDuration: 184_001),
            try await liveLyrics(candidateTitle: "Sample", candidateDuration: nil),
            try await liveLyrics(candidateTitle: "Sample", hash: nil),
            try await liveLyrics(candidateTitle: "Sample", duration: nil)
        ]
        try expect(rejected.allSatisfy { $0 == nil }, "Live-title fallback requires the recording hash, artist, duration and base title")
        print("PASS Kugou live-title lyric matching and exact title precedence")
    }

    @MainActor private static func testBatchLookup(session: URLSession) async throws {
        let cover = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jft8AAAAASUVORK5CYII=")!
        let lyric = "[00:01.00]First song"
        let translation = "[00:01.00]第一首歌"
        func song(_ id: Int, _ title: String, _ artist: String, _ album: String, _ duration: Int) -> [String: Any] {
            ["songid": id, "songmid": String(id), "songname": title, "singer": artist.components(separatedBy: "/").map { ["name": $0] },
             "albumname": album, "albummid": "Cover\(id)", "interval": duration]
        }
        let rows = [song(1, "First", "Other Artist", "Original", 180),
                    song(2, "First", "Artist A", "Original", 210),
                    song(3, "First", "Artist A", "Original", 180),
                    song(4, "First", "Artist A", "Other Album", 180),
                    song(5, "Second", "Artist B", "Second Album", 180),
                    song(6, "我的骄傲 (Live)", "糖妹/安崎/炎明熹", "声生不息 第10期", 240),
                    song(7, "我的骄傲 (Radio Mix)", "糖妹/安崎/炎明熹", "声生不息 第10期", 240),
                    song(8, "我的骄傲 (Live)", "糖妹/安崎", "声生不息 第10期", 240),
                    song(9, "我的骄傲 (Live)", "糖妹/安崎/炎明熹", "Other Album", 240),
                    song(10, "我的骄傲 (Live)", "糖妹/安崎/炎明熹", "声生不息 第10期", 230),
                    song(11, "First (Live)", "Artist A", "Original", 180),
                    song(12, "Third (Live)", "Artist C", "Third Album", 180),
                    song(13, "Third（现场版）", "Artist C", "Third Album", 180),
                    song(14, "Fourth (Live)", "Artist D", "Fourth Album", 0)]
        let response = try json(["code": 0, "data": ["song": ["list": rows]]])
        StubProtocol.handler = { request in
            let url = request.url!
            switch url.host {
            case "u.y.qq.com":
                let data = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "data" }?.value
                let root = try OnlineLookup.object(Data((data ?? "").utf8))
                guard let service = root["req_0"] as? [String: Any],
                      service["module"] as? String == "music.musichallSong.PlayLyricInfo" else { return (503, Data()) }
                let param = service["param"] as? [String: Any]
                try expect(service["method"] as? String == "GetPlayLyricInfo" && param?["crypt"] as? Int == 0 && param?["qrc"] as? Int == 0, "QQ requests unencrypted LRC")
                let id = (param?["songMid"] as? String).flatMap(Int.init)
                let lyrics: [String: Any]
                switch id {
                case 3:
                    lyrics = ["songID": 3, "lyric": Data(lyric.utf8).base64EncodedString(),
                              "trans": param?["trans"] as? Int == 1 ? Data(translation.utf8).base64EncodedString() : ""]
                case 5:
                    return (200, try json(["code": 0, "req_0": ["code": 24001]]))
                case 6:
                    lyrics = ["songID": 9, "lyric": lyric]
                case 12, 13:
                    lyrics = ["songID": id ?? 0, "lyric": lyric, "trans": "[by:credit]\n[00:01.00]"]
                default:
                    throw AppError.message("Unexpected QQ song MID")
                }
                let result: [String: Any] = ["code": 0, "data": lyrics]
                return (200, try json(["code": 0, "req_0": result]))
            case "y.qq.com": return url.path.contains("Cover3") ? (200, cover) : (200, Data("invalid image".utf8))
            case "c.y.qq.com":
                if url.path == "/soso/fcgi-bin/search_for_qq_cp" { return (200, response) }
                let mid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "songmid" }?.value
                if mid == "3" { throw AppError.message("Unexpected legacy lyric request") }
                if mid == "12" { return (200, try json(["code": 0, "lyric": lyric, "trans": translation])) }
                return mid == "6" ? (200, try json(["code": 0, "lyric": lyric])) : (503, Data())
            default: throw AppError.message("Batch lookup used an unexpected source")
            }
        }

        func track(_ filename: String, tags: AudioTags, duration: Double = 180) -> TrackItem {
            TrackItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(filename)"), tags: tags, savedTags: tags,
                      duration: duration, size: 0, sampleRate: 0, channels: 0, issue: nil)
        }
        var firstTags = AudioTags()
        firstTags.album = "Original"
        firstTags.composer = "Local composer"
        let first = track("Artist A - First.flac", tags: firstTags)
        let second = track("Unknown.wav", tags: AudioTags(title: "Second", artist: "ARTIST B", lyrics: "Local lyrics", artwork: cover))
        let readOnly = track("Read Only.wave", tags: AudioTags())
        let firstResult = try await OnlineLookup.batchResult(for: first, source: .qq, session: session)
        let secondResult = try await OnlineLookup.batchResult(for: second, source: .qq, session: session)
        var plainOptions = LyricOptions()
        plainOptions.removeTimes = true
        let formatted = try await OnlineLookup.batchResult(for: first, source: .qq, options: plainOptions, session: session)
        let previewed = try await OnlineLookup.lyrics(for: firstResult.song, options: plainOptions, session: session)
        try expect(formatted.lyrics == "First song 第一首歌" && formatted.lyrics == previewed, "Batch and individual lookup return QQ translations using the same format settings")
        try expect(firstResult.song.trackId == 3 && firstResult.artwork == cover && firstResult.lyrics == lyric + " 第一首歌", "Use filename, duration and album to choose the correct recording")
        plainOptions.translationEnabled = false
        let original = try await OnlineLookup.lyrics(for: firstResult.song, options: plainOptions, session: session)
        try expect(original == "First song", "QQ returns the original when translations are off")
        let legacyTranslation = try await OnlineLookup.lyrics(for: CatalogSong(source: .qq, trackId: 12, songMid: "12"), session: session)
        try expect(legacyTranslation == lyric + " 第一首歌", "Prefer the legacy endpoint when only it has usable translated lines")
        let modernOriginal = try await OnlineLookup.lyrics(for: CatalogSong(source: .qq, trackId: 13, songMid: "13"), session: session)
        try expect(modernOriginal == lyric, "Preserve the modern original if the legacy endpoint fails")
        try expect(secondResult.song.trackId == 5 && secondResult.artwork == nil && secondResult.lyrics == nil, "Keep the tag match when the image or lyrics fail")

        let liveTags = AudioTags(title: "我的骄傲", artist: "糖妹;安崎;炎明熹", album: "声生不息 第10期")
        let live = track("我的骄傲.flac", tags: liveTags, duration: 240.026667)
        let liveResult = try await OnlineLookup.batchResult(for: live, source: .qq, session: session)
        try expect(liveResult.song.trackId == 6 && liveResult.song.trackName == "我的骄傲 (Live)", "Use the confirmed live recording and retain the provider title")
        try expect(liveResult.lyrics == lyric, "Reject modern lyrics for a different song and use the legacy QQ endpoint")
        var missingAlbum = live
        missingAlbum.tags.album = ""
        var missingDuration = live
        missingDuration.duration = 0
        var wrongDuration = live
        wrongDuration.duration = 250
        let ambiguousLive = track("Artist C - Third.flac", tags: AudioTags(album: "Third Album"))
        let unknownCatalogDuration = track("Artist D - Fourth.flac", tags: AudioTags(album: "Fourth Album"))
        for (item, reason) in [(track("Artist A - First.flac", tags: AudioTags()), "多个"),
                               (track("Artist A - Missing.flac", tags: AudioTags()), "没有可靠"),
                               (track("Artist missing.flac", tags: AudioTags()), "缺少"),
                               (missingAlbum, "没有可靠"), (missingDuration, "没有可靠"),
                               (wrongDuration, "没有可靠"), (unknownCatalogDuration, "没有可靠"),
                               (ambiguousLive, "多个")] {
            do {
                _ = try await OnlineLookup.batchResult(for: item, source: .qq, session: session)
                throw AppError.message("Unsafe batch match")
            } catch let error as AppError {
                try expect(error.localizedDescription.contains(reason), "Batch lookup must skip uncertain songs")
            }
        }

        let suiteName = "MusicTag-LookupTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(defaults: defaults)
        try expect(store.lyricOptions == LyricOptions(), "Fresh settings use formatter defaults")
        store.lyricOptions = plainOptions
        try expect(LibraryStore(defaults: defaults).lyricOptions == plainOptions, "Settings survive reinitialization in the same suite")
        defaults.removeObject(forKey: "lyricOptions")
        defaults.set(["/tmp/Old Music Library"], forKey: "lastImportedDirectoryPaths")
        try expect(LibraryStore(defaults: defaults).lyricOptions.layout == .sections, "An existing library retains the old bilingual layout")
        store.tracks = [first, second, readOnly]
        store.selection = [readOnly.id]
        let results = [first.id: firstResult, second.id: secondResult, readOnly.id: secondResult]
        let updated = store.mutateTracks(targetIDs: Set(results.keys)) { id, tags in results[id]?.applying(to: &tags) }
        try expect(updated == 2 && store.dirtyCount == 2, "Batch results apply to their own writable targets")
        try expect(store.tracks[0].tags.title == "First" && store.tracks[0].tags.lyrics == lyric + " 第一首歌" && store.tracks[0].tags.composer == "Local composer", "Apply the first song's tags and resources together")
        try expect(store.tracks[1].tags.title == "Second" && store.tracks[1].tags.lyrics == "Local lyrics" && store.tracks[1].tags.artwork == cover, "Preserve the second song's unavailable resources")
        try expect(store.tracks[2] == readOnly, "Leave read-only targets untouched")
        try expect(store.mutateTracks(targetIDs: Set(results.keys)) { id, tags in results[id]?.applying(to: &tags) } == 0, "Retrying identical results produces no undo step")
        store.undo()
        try expect(store.tracks == [first, second, readOnly] && !store.canUndo, "Undo all songs in one step")
        print("PASS batch lookup: per-song matching, confirmed live versions, ambiguous versions, partial resources, read-only targets and single-step undo")
    }
}
