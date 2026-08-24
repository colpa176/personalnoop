// Test-only URLProtocol for the STRAVA_CLOUD_IMPORT-gated Strava lane. Serves canned responses by
// request order (like OuraURLProtocolStub) but ALSO carries optional response headers, so the
// rate-limit-header parsing path is exercisable.
#if STRAVA_CLOUD_IMPORT
import Foundation

final class StravaURLProtocolStub: URLProtocol {
    struct Stubbed { let status: Int; let body: Data; let headers: [String: String]
        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status; self.body = body; self.headers = headers
        }
    }
    /// FIFO queue of responses; each request pops the next. Set before the test acts.
    nonisolated(unsafe) static var queue: [Stubbed] = []
    /// Captured request URLs, in order, for assertions.
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() { queue = []; requestedURLs = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let u = request.url { Self.requestedURLs.append(u) }
        let s = Self.queue.isEmpty ? Stubbed(status: 500, body: Data()) : Self.queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status,
                                   httpVersion: nil, headerFields: s.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// A URLSession wired to this stub.
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StravaURLProtocolStub.self]
        return URLSession(configuration: cfg)
    }
}
#endif // STRAVA_CLOUD_IMPORT
