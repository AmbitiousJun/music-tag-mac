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
                let isArtwork = components.host == "y.qq.com"
                    && components.path == "/music/photo_new/T002R800x800M000fixture-apply-all.jpg"
                let body: Data
                if isArtwork {
                    // A 24 × 18 PNG, with dimensions distinct from the local 32 × 32 cover.
                    body = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAG0lEQVR4nGOYwNFMFcQwatCoQaMGjRo03AwCAAF43aBdbjGIAAAAAElFTkSuQmCC")!
                } else {
                    body = try JSONSerialization.data(withJSONObject: payload(for: components))
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

        private func payload(for url: URLComponents) throws -> [String: Any] {
            let params = url.queryItems ?? []
            switch (url.host, url.path) {
            case ("u.y.qq.com", "/cgi-bin/musicu.fcg"):
                let raw = params.first { $0.name == "data" }?.value ?? ""
                let body = try JSONDecoder().decode(MusicuRequest.self, from: Data(raw.utf8))
                if body.req_0.method == "GetPlayLyricInfo" {
                    guard body.req_0.module == "music.musichallSong.PlayLyricInfo",
                          body.req_0.param.type == 1, body.req_0.param.trans == 1, body.req_0.param.crypt == 0,
                          body.req_0.param.qrc == 0, let mid = body.req_0.param.songMid,
                          let songIndex = songMids.firstIndex(of: mid) else {
                        throw URLError(.resourceUnavailable)
                    }
                    let original = "[ti:测试歌]\n[00:01.2]First line\n[00:02.30]Second line"
                    let translation = "[00:01.20]第一行\n[00:02.300]第二行"
                    return ["code": 0, "req_0": ["code": 0, "data": [
                        "songID": songIndex + 1,
                        "lyric": Data(original.utf8).base64EncodedString(),
                        "trans": Data(translation.utf8).base64EncodedString()
                    ]]]
                }
                if body.req_0.param.query == "Apply All Fixture" {
                    let rows: [[String: Any]] = [[
                        "id": 4, "mid": "fixture-apply-all", "name": "Online Title",
                        "singer": [["name": "Online Artist"]],
                        "album": ["name": "Online Album", "mid": "fixture-apply-all"]
                    ]]
                    return ["code": 0, "req_0": ["data": ["body": ["song": ["list": rows]]]]]
                }
                let song = ["First Song", "Second Song", "Third Song"].enumerated()
                    .first { body.req_0.param.query == "Artist \($0.offset + 1) \($0.element)" }
                let rows: [[String: Any]] = song.map { match in
                    let number = match.offset + 1
                    return [[
                        "id": number, "mid": "fixture-\(number)", "name": match.element,
                        "singer": [["name": "Artist \(number)"]],
                        "album": ["name": "Original Album \(number)"], "interval": 20
                    ]]
                } ?? []
                return ["code": 0, "req_0": ["data": ["body": ["song": ["list": rows]]]]]
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
                let query: String?
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
