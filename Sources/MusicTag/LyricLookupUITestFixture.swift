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
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                guard let url = request.url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Content-Type": "application/json"]) else {
                    throw URLError(.badURL)
                }
                let body = try JSONSerialization.data(withJSONObject: payload(for: components))
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
                let body = try JSONDecoder().decode(SearchRequest.self, from: Data(raw.utf8))
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
                guard ["fixture-1", "fixture-2", "fixture-3"].contains(mid) else {
                    throw URLError(.resourceUnavailable)
                }
                let original = "[ti:测试歌]\n[00:01.2]第一行\n[00:02.30]第二行"
                let translation = "[00:01.20]First line\n[00:02.300]Second line"
                return ["retcode": 0, "lyric": Data(original.utf8).base64EncodedString(),
                        "trans": Data(translation.utf8).base64EncodedString()]
            default:
                throw URLError(.resourceUnavailable)
            }
        }

        private struct SearchRequest: Decodable {
            struct Arguments: Decodable { let query: String }
            struct Endpoint: Decodable { let param: Arguments }
            let req_0: Endpoint
        }
    }
}
#endif
