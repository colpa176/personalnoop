// Tests the STRAVA_CLOUD_IMPORT-gated Strava API client; compiled only when the flag is set.
#if STRAVA_CLOUD_IMPORT
import XCTest
import AuthenticationServices
@testable import Strand

/// A stub AuthProvider that hands out a fixed token and counts refreshes.
private final class StubAuth: AuthProvider {
    var token = "tok-1"
    var refreshCount = 0
    var isConnected: Bool { true }
    func validAccessToken() async throws -> String { token }
    func refreshedAccessToken() async throws -> String { refreshCount += 1; token = "tok-refreshed"; return token }
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws {}
    func signOut() {}
}

final class StravaAPIClientTests: XCTestCase {
    override func setUp() { super.setUp(); StravaURLProtocolStub.reset() }

    private func page(_ n: Int, ids: [Int]) -> StravaURLProtocolStub.Stubbed {
        let rows = ids.map { #"{"id":\#($0),"type":"Run","start_date":"2026-01-0\#($0)T06:00:00Z","elapsed_time":600}"# }
        return .init(status: 200, body: "[\(rows.joined(separator: ","))]".data(using: .utf8)!)
    }

    // MARK: - Pagination (page-number; terminates on an EMPTY page)

    func testPaginationWalksPagesUntilEmptyPage() async throws {
        // Terminates on the EMPTY page, not the short one: page1 (2 rows), page2 (1 row), page3 empty.
        StravaURLProtocolStub.queue = [page(1, ids: [1, 2]), page(2, ids: [3]),
                                       .init(status: 200, body: "[]".data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), perPage: 2)
        var collected: [[String: Any]] = []
        var pages = 0
        try await client.forEachActivityPage(after: nil) { rows, _ in collected += rows; pages += 1 }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(StravaURLProtocolStub.requestedURLs.count, 3)
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[0].absoluteString.contains("page=1"))
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[2].absoluteString.contains("page=3"))
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[0].absoluteString.contains("per_page=2"))
    }

    /// Regression guard: a server-side per_page cap must NOT truncate the import. If Strava caps pages
    /// below what we request, every page looks "short" — stopping on that would silently lose history.
    func testShortPageDoesNotStopPagination() async throws {
        StravaURLProtocolStub.queue = [
            page(1, ids: [1]),                                        // 1 row while perPage=200
            page(2, ids: [2]),
            .init(status: 200, body: "[]".data(using: .utf8)!),
        ]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), perPage: 200)
        var collected: [[String: Any]] = []
        try await client.forEachActivityPage(after: nil) { rows, _ in collected += rows }
        XCTAssertEqual(collected.count, 2, "short pages must keep paging until an empty page")
    }

    func testNonArrayBodyThrowsDecodeRatherThanEndingSilently() async throws {
        StravaURLProtocolStub.queue = [.init(status: 200, body: #"{"message":"oops"}"#.data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session())
        do {
            try await client.forEachActivityPage(after: nil) { _, _ in }
            XCTFail("expected a decode error, not a silent stop")
        } catch { /* expected */ }
    }

    func testEmptyFirstPageStopsImmediately() async throws {
        StravaURLProtocolStub.queue = [.init(status: 200, body: "[]".data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), perPage: 200)
        var pages = 0
        try await client.forEachActivityPage(after: nil) { _, _ in pages += 1 }
        XCTAssertEqual(pages, 0)
    }

    func testAfterCursorIncludedInQuery() async throws {
        StravaURLProtocolStub.queue = [.init(status: 200, body: "[]".data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), perPage: 200)
        try await client.forEachActivityPage(after: 1_700_000_000) { _, _ in }
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs.first?.absoluteString.contains("after=1700000000") ?? false)
    }

    func testNilAfterOmitsAfterParam() async throws {
        StravaURLProtocolStub.queue = [.init(status: 200, body: "[]".data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session())
        try await client.forEachActivityPage(after: nil) { _, _ in }
        XCTAssertFalse(StravaURLProtocolStub.requestedURLs.first?.absoluteString.contains("after=") ?? true)
    }

    // MARK: - 429 + 401 handling

    func test429IsRetriedAfterBackoff() async throws {
        StravaURLProtocolStub.queue = [
            .init(status: 429, body: Data()),
            page(1, ids: [1]),
            .init(status: 200, body: "[]".data(using: .utf8)!),   // empty page terminates the loop
        ]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(),
                                     backoff: 0, perPage: 200)
        var collected: [[String: Any]] = []
        try await client.forEachActivityPage(after: nil) { rows, _ in collected += rows }
        XCTAssertEqual(collected.count, 1)
    }

    func test401TriggersRefreshThenRetrySucceeds() async throws {
        StravaURLProtocolStub.queue = [
            .init(status: 401, body: Data()),
            page(1, ids: [1]),
            .init(status: 200, body: "[]".data(using: .utf8)!),   // empty page terminates the loop
        ]
        let stub = StubAuth()
        let client = StravaAPIClient(auth: stub, session: StravaURLProtocolStub.session(), perPage: 200)
        var collected: [[String: Any]] = []
        try await client.forEachActivityPage(after: nil) { rows, _ in collected += rows }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(stub.refreshCount, 1)         // refreshed exactly once
    }

    func testUnhandledStatusThrows() async throws {
        StravaURLProtocolStub.queue = [.init(status: 500, body: "boom".data(using: .utf8)!)]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session())
        do {
            try await client.forEachActivityPage(after: nil) { _, _ in }
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    // MARK: - Rate-limit headers

    func testRateLimitHeaderParsing() throws {
        let http = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 429,
            httpVersion: nil, headerFields: ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "34,512"]))
        let rl = try XCTUnwrap(StravaRateLimit.from(http))
        XCTAssertEqual(rl.limit15min, 200); XCTAssertEqual(rl.limitDaily, 2000)
        XCTAssertEqual(rl.usage15min, 34); XCTAssertEqual(rl.usageDaily, 512)
        XCTAssertEqual(rl.summary, "34/200 in 15 min, 512/2000 today")

        let bare = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
            httpVersion: nil, headerFields: [:]))
        XCTAssertNil(StravaRateLimit.from(bare))
    }

    /// Exhausting the retries surfaces the rate-limit usage in the user-facing error, and the client keeps
    /// no cross-request mutable state to do it.
    func testPersistent429SurfacesRateLimitDetail() async throws {
        let headers = ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "200,900"]
        StravaURLProtocolStub.queue = (0..<3).map { _ in
            StravaURLProtocolStub.Stubbed(status: 429, body: Data(), headers: headers)
        }
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), backoff: 0)
        do {
            try await client.forEachActivityPage(after: nil) { _, _ in }
            XCTFail("expected rateLimited")
        } catch let e as StravaError {
            guard case .rateLimited(let detail) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(detail, "200/200 in 15 min, 900/2000 today")
        }
    }
}
#endif // STRAVA_CLOUD_IMPORT
