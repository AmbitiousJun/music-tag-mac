#if UI_TESTING
import Foundation

enum LyricLookupUITestFixture {
    static let session: URLSession? = {
        guard ProcessInfo.processInfo.environment["MUSICTAG_UI_TEST_LYRICS_FIXTURE"] == "1" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private final class FixtureProtocol: URLProtocol {
        private let songMids = ["fixture-1", "fixture-2", "fixture-3", "fixture-apply-all"]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                guard let url = request.url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw URLError(.badURL)
                }
                let isArtwork = (components.host == "y.qq.com"
                    && components.path == "/music/photo_new/T002R800x800M000fixture-apply-all.jpg")
                    || (components.host == "imge.kugou.com" && components.path == "/stdmusic/800/fixture.png")
                let body: Data
                if isArtwork {
                    // A 24 × 18 PNG, with dimensions distinct from the local 32 × 32 cover.
                    body = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAG0lEQVR4nGOYwNFMFcQwatCoQaMGjRo03AwCAAF43aBdbjGIAAAAAElFTkSuQmCC")!
                } else {
                    recordSearch(components)
                    let result: Any
                    if components.host == "lrclib.net", components.path == "/api/search" {
                        result = lrclibSearchPayload(for: components)
                    } else {
                        result = try payload(for: components)
                    }
                    body = try JSONSerialization.data(withJSONObject: result)
                }
                let contentType = isArtwork ? "image/png" : "application/json"
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                      headerFields: ["Content-Type": contentType]) else {
                    throw URLError(.badURL)
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private func recordSearch(_ url: URLComponents) {
            guard let directory = ProcessInfo.processInfo.environment["MUSICTAG_UI_TEST_LOOKUP_REQUESTS"] else { return }
            let source: String
            switch (url.host, url.path) {
            case ("c.y.qq.com", "/soso/fcgi-bin/search_for_qq_cp"): source = "qq"
            case ("music.163.com", "/weapi/cloudsearch/pc"): source = "netease"
            case ("songsearch.kugou.com", "/song_search_v2"): source = "kugou"
            case ("itunes.apple.com", "/search"): source = "itunes"
            case ("lrclib.net", "/api/search"): source = "lrclib"
            default: return
            }
            let marker = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(source)
            try? Data().write(to: marker, options: .atomic)
        }

        private func lrclibSearchPayload(for url: URLComponents) -> [[String: Any]] {
            guard url.queryItems?.contains(where: { $0.name == "q" && $0.value == "Aggregate Fixture" }) == true else {
                return []
            }
            return [["id": 1, "trackName": "Aggregate Fixture Lyrics", "artistName": "Lyrics Artist",
                     "syncedLyrics": "[00:01.00]Lyrics from LRCLIB"]]
        }

        private func payload(for url: URLComponents) throws -> [String: Any] {
            let params = url.queryItems ?? []
            switch (url.host, url.path) {
            case ("u.y.qq.com", "/cgi-bin/musicu.fcg"):
                let raw = params.first { $0.name == "data" }?.value ?? ""
                let body = try JSONDecoder().decode(MusicuRequest.self, from: Data(raw.utf8))
                guard body.req_0.method == "GetPlayLyricInfo",
                      body.req_0.module == "music.musichallSong.PlayLyricInfo",
                      body.req_0.param.type == 1, body.req_0.param.trans == 1, body.req_0.param.crypt == 0,
                      body.req_0.param.qrc == 0, let mid = body.req_0.param.songMid,
                      let songIndex = songMids.firstIndex(of: mid) else {
                    throw URLError(.resourceUnavailable)
                }
                let original = "[ti:测试歌]\n[00:01.2]First line\n[00:02.30]Second line"
                let translation = "[00:01.20]第一行\n[00:02.300]第二行"
                let lyrics: [String: Any] = [
                    "songID": songIndex + 1,
                    "lyric": Data(original.utf8).base64EncodedString(),
                    "trans": Data(translation.utf8).base64EncodedString()
                ]
                let response: [String: Any] = ["code": 0, "data": lyrics]
                return ["code": 0, "req_0": response]
            case ("c.y.qq.com", "/soso/fcgi-bin/search_for_qq_cp"):
                let query = params.first { $0.name == "w" }?.value ?? ""
                let rows: [[String: Any]]
                switch query {
                case "Aggregate Fixture":
                    rows = [[
                        "songid": 1, "songmid": "fixture-1", "songname": "Fixture Loose Match",
                        "singer": [["name": "Other Artist"]], "albumname": "Other Album"
                    ]]
                case "Apply All Fixture":
                    rows = [[
                        "songid": 4, "songmid": "fixture-apply-all", "songname": "Online Title",
                        "singer": [["name": "Online Artist"]],
                        "albumname": "Online Album", "albummid": "fixture-apply-all"
                    ]]
                default:
                    let song = ["First Song", "Second Song", "Third Song"].enumerated()
                        .first { query == "Artist \($0.offset + 1) \($0.element)" }
                    rows = song.map { match in
                        let number = match.offset + 1
                        return [[
                            "songid": number, "songmid": "fixture-\(number)", "songname": match.element,
                            "singer": [["name": "Artist \(number)"]],
                            "albumname": "Original Album \(number)", "interval": 20
                        ]]
                    } ?? []
                }
                return ["code": 0, "data": ["song": ["list": rows]]]
            case ("songsearch.kugou.com", "/song_search_v2"):
                let query = params.first { $0.name == "keyword" }?.value ?? ""
                if query == "Aggregate Fixture" {
                    let row: [String: Any] = ["ID": "1", "SongName": "Aggregate Fixture (Live)",
                                               "Singers": [["name": "Kugou Artist"]], "AlbumName": "Kugou Album"]
                    return ["status": 1, "error_code": 0, "data": ["lists": [row]]]
                }
                let songs = ["First Song", "Second Song", "Third Song"]
                let rows: [[String: Any]] = songs.enumerated().compactMap { index, title in
                    let number = index + 1
                    let artist = "Artist \(number)"
                    guard query == "\(artist) \(title)" else { return nil }
                    return [
                        "ID": "\(number)", "SongName": title, "Singers": [["name": artist]],
                        "AlbumName": "Kugou Album \(number)", "PublishDate": "2024-01-08",
                        "Duration": 20, "FileHash": "fixture-kugou-\(number)",
                        "Image": "http://imge.kugou.com/stdmusic/{size}/fixture.png"
                    ]
                }
                return ["status": 1, "error_code": 0, "data": ["lists": rows]]
            case ("itunes.apple.com", "/search"):
                let query = params.first { $0.name == "term" }?.value
                let rows: [[String: Any]] = query == "Aggregate Fixture" ? [[
                    "trackId": 1, "trackName": "Aggregate Fixture", "artistName": "iTunes Artist",
                    "collectionName": "iTunes Album", "trackTimeMillis": 20_000
                ]] : []
                return ["results": rows]
            case ("lyrics.kugou.com", "/search"):
                let hash = params.first { $0.name == "hash" }?.value ?? ""
                let songs = ["First Song", "Second Song", "Third Song"]
                let candidates: [[String: Any]] = songs.enumerated().compactMap { index, title in
                    let number = index + 1
                    guard hash == "fixture-kugou-\(number)" else { return nil }
                    return ["id": "\(number)", "accesskey": "fixture", "song": title, "singer": "Artist \(number)", "duration": 20_000]
                }
                return ["status": 200, "candidates": candidates]
            case ("lyrics.kugou.com", "/download"):
                guard params.contains(where: { $0.name == "fmt" && $0.value == "krc" }) else {
                    throw URLError(.resourceUnavailable)
                }
                // A synthetic two-line KRC sample with word timings and a translation layer.
                return ["status": 200, "content": "a3JjMTjbXL6fOPZ3TbbAloEDbRG47E1d9HEtc9qUtRvb3UCu2MpMK3jIgMITkT5TkXRkRNoFkXKxkP6+WWSzLZmU/qmKtcGtavQnW78a72tYAYb8gL6igxMDCdJGj1CJ9TuUsX9cfW3NhuaB/M6qxIlpFRoKJvRMx9V3/2K2TRQKV5s3lrFcJgxBU7TSKZDcbDOolSEzWJtx3pd/Uw=="]
            case ("c.y.qq.com", "/lyric/fcgi-bin/fcg_query_lyric_new.fcg"):
                let mid = params.first { $0.name == "songmid" }?.value
                guard let mid, songMids.contains(mid) else {
                    throw URLError(.resourceUnavailable)
                }
                // Some songs only have the original lyrics on this legacy endpoint.
                let original = "[00:01.20]First line\n[00:02.30]Second line"
                return ["retcode": 0, "lyric": Data(original.utf8).base64EncodedString(), "trans": ""]
            default:
                throw URLError(.resourceUnavailable)
            }
        }

        private struct MusicuRequest: Decodable {
            struct Arguments: Decodable {
                let songMid: String?
                let type: Int?
                let trans: Int?
                let crypt: Int?
                let qrc: Int?
            }
            struct Endpoint: Decodable {
                let module: String
                let method: String
                let param: Arguments
            }
            let req_0: Endpoint
        }
    }
}
#endif
