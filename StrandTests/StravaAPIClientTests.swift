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

    // MARK: - Pagination (page-number, stop on short page)

    func testPaginationWalksPagesUntilShortPage() async throws {
        // per_page=2: page1 full (2 rows) → continue; page2 short (1 row) → stop. Page 3 never requested.
        StravaURLProtocolStub.queue = [page(1, ids: [1, 2]), page(2, ids: [3])]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session(), perPage: 2)
        var collected: [[String: Any]] = []
        var pages = 0
        try await client.forEachActivityPage(after: nil) { rows, _ in collected += rows; pages += 1 }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(StravaURLProtocolStub.requestedURLs.count, 2)
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[0].absoluteString.contains("page=1"))
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[1].absoluteString.contains("page=2"))
        XCTAssertTrue(StravaURLProtocolStub.requestedURLs[0].absoluteString.contains("per_page=2"))
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
            page(1, ids: [1]),                       // short page → stops after success
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

    func testRateLimitHeadersCaptured() async throws {
        StravaURLProtocolStub.queue = [.init(status: 200, body: "[]".data(using: .utf8)!,
            headers: ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "34,512"])]
        let client = StravaAPIClient(auth: StubAuth(), session: StravaURLProtocolStub.session())
        try await client.forEachActivityPage(after: nil) { _, _ in }
        let rl = try XCTUnwrap(client.lastRateLimit)
        XCTAssertEqual(rl.limit15min, 200); XCTAssertEqual(rl.limitDaily, 2000)
        XCTAssertEqual(rl.usage15min, 34); XCTAssertEqual(rl.usageDaily, 512)
    }
}
#endif // STRAVA_CLOUD_IMPORT
