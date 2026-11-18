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
        try expect(decoded == lrc + "\n[00:01.00]Hello", "QQ Base64")
        let wrapped = Data("MusicJsonCallback(\(String(decoding: try json(["code": 0, "lyric": "[00:01.00]A &#38; B &quot;C&quot;"]), as: UTF8.self)));".utf8)
        try expect(try OnlineLookup.parseLyrics(wrapped, source: .qq) == "[00:01.00]A & B \"C\"", "QQ JSONP and entities")
        try expect(try OnlineLookup.parseLyrics(json(["code": 200, "lrc": ["lyric": lrc], "tlyric": ["lyric": "[00:01.00]译文"]]), source: .netease).contains("译文"), "NetEase lyrics")
        for (source, value) in [(LookupSource.qq, ["code": 0, "lyric": ""] as [String: Any]), (.netease, ["code": 200, "nolyric": true])] {
            do { _ = try OnlineLookup.parseLyrics(json(value), source: source); throw AppError.message("accepted empty lyric") }
            catch let error as AppError { try expect(error.localizedDescription.contains("暂无"), "empty lyric handling") }
        }
        print("PASS Base64 / JSONP / entity decoding, translations and missing lyrics")
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
        StubProtocol.handler = { request in
            try expect(request.url?.scheme == "https" && request.value(forHTTPHeaderField: "Referer") == "https://i.y.qq.com/", "QQ request headers")
            let data = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "data" }!.value!
            try expect(!request.url!.absoluteString.contains(":" + "0"), "QQ JSON query encoding")
            let payload = try OnlineLookup.object(Data(data.utf8)); let req = payload["req_0"] as! [String: Any]; let param = req["param"] as! [String: Any]
            try expect(param["query"] as? String == "A\"B\\C & 中文+", "QQ JSON/query escaping")
            try expect(param["num_per_page"] as? Int == 20, "QQ supported page size")
            return (200, qqFixture)
        }
        let songs = try await OnlineLookup.songs(query: "A\"B\\C & 中文+", source: .qq, session: session)
        try expect(songs.count == 1, "QQ request parse")
        let legacyFixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("qq-legacy-search.json"))
        StubProtocol.handler = { request in
            if request.url?.host == "u.y.qq.com" { return (200, try json(["code": 0, "req_0": ["code": 2001]])) }
            try expect(request.url?.host == "c.y.qq.com", "QQ fallback host")
            return (200, legacyFixture)
        }
        let fallback = try await OnlineLookup.songs(query: "周杰伦 晴天", source: .qq, session: session)[0]
        try expect(fallback.trackName == qq.trackName && fallback.trackId == qq.trackId && fallback.artworkURL == qq.artworkURL && fallback.trackNumber == 3 && fallback.discNumber == 1 && fallback.releaseDate == "2003-07-31", "QQ fallback identities / date / numbering")
        print("PASS QQ 2001 fallback: real legacy fixture, stable identities and metadata")
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
    }

    @MainActor private static func testBatchLookup(session: URLSession) async throws {
        let cover = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jft8AAAAASUVORK5CYII=")!
        let lyric = "[00:01.00]First song"
        func song(_ id: Int, _ title: String, _ artist: String, _ album: String, _ duration: Int) -> [String: Any] {
            ["id": id, "mid": String(id), "title": title, "singer": [["name": artist]],
             "album": ["title": album, "mid": "Cover\(id)"], "interval": duration]
        }
        let rows = [song(1, "First", "Other Artist", "Original", 180),
                    song(2, "First", "Artist A", "Original", 210),
                    song(3, "First", "Artist A", "Original", 180),
                    song(4, "First", "Artist A", "Other Album", 180),
                    song(5, "Second", "Artist B", "Second Album", 180)]
        let payload: [String: Any] = ["code": 0, "data": ["body": ["song": ["list": rows]]]]
        let response = try json(["code": 0, "req_0": payload])
        StubProtocol.handler = { request in
            let url = request.url!
            switch url.host {
            case "u.y.qq.com": return (200, response)
            case "y.qq.com": return url.path.contains("Cover3") ? (200, cover) : (200, Data("invalid image".utf8))
            case "c.y.qq.com":
                let mid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "songmid" }?.value
                return mid == "3" ? (200, try json(["code": 0, "lyric": lyric])) : (503, Data())
            default: throw AppError.message("Batch lookup used an unexpected source")
            }
        }

        func track(_ filename: String, tags: AudioTags) -> TrackItem {
            TrackItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(filename)"), tags: tags, savedTags: tags,
                      duration: 180, size: 0, sampleRate: 0, channels: 0, issue: nil)
        }
        var firstTags = AudioTags()
        firstTags.album = "Original"
        firstTags.composer = "Local composer"
        let first = track("Artist A - First.flac", tags: firstTags)
        let second = track("Unknown.wav", tags: AudioTags(title: "Second", artist: "ARTIST B", lyrics: "Local lyrics", artwork: cover))
        let readOnly = track("Read Only.wave", tags: AudioTags())
        let firstResult = try await OnlineLookup.batchResult(for: first, source: .qq, session: session)
        let secondResult = try await OnlineLookup.batchResult(for: second, source: .qq, session: session)
        try expect(firstResult.song.trackId == 3 && firstResult.artwork == cover && firstResult.lyrics == lyric, "Use filename, duration and album to choose the correct recording")
        try expect(secondResult.song.trackId == 5 && secondResult.artwork == nil && secondResult.lyrics == nil, "Keep the tag match when the image or lyrics fail")

        for (item, reason) in [(track("Artist A - First.flac", tags: AudioTags()), "多个"),
                               (track("Artist A - Missing.flac", tags: AudioTags()), "没有可靠"),
                               (track("Artist missing.flac", tags: AudioTags()), "缺少")] {
            do {
                _ = try await OnlineLookup.batchResult(for: item, source: .qq, session: session)
                throw AppError.message("Unsafe batch match")
            } catch let error as AppError {
                try expect(error.localizedDescription.contains(reason), "Batch lookup must skip uncertain songs")
            }
        }

        let store = LibraryStore()
        store.tracks = [first, second, readOnly]
        store.selection = [readOnly.id]
        let results = [first.id: firstResult, second.id: secondResult, readOnly.id: secondResult]
        let updated = store.mutateTracks(targetIDs: Set(results.keys)) { id, tags in results[id]?.applying(to: &tags) }
        try expect(updated == 2 && store.dirtyCount == 2, "Batch results apply to their own writable targets")
        try expect(store.tracks[0].tags.title == "First" && store.tracks[0].tags.lyrics == lyric && store.tracks[0].tags.composer == "Local composer", "Apply the first song's tags and resources together")
        try expect(store.tracks[1].tags.title == "Second" && store.tracks[1].tags.lyrics == "Local lyrics" && store.tracks[1].tags.artwork == cover, "Preserve the second song's unavailable resources")
        try expect(store.tracks[2] == readOnly, "Leave read-only targets untouched")
        try expect(store.mutateTracks(targetIDs: Set(results.keys)) { id, tags in results[id]?.applying(to: &tags) } == 0, "Retrying identical results produces no undo step")
        store.undo()
        try expect(store.tracks == [first, second, readOnly] && !store.canUndo, "Undo all songs in one step")
        print("PASS batch lookup: per-song matching, ambiguous versions, partial resources, read-only targets and single-step undo")
    }
}
