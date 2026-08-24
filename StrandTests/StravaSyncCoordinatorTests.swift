// Tests the STRAVA_CLOUD_IMPORT-gated Strava import lane; compiled only when the flag is set.
#if STRAVA_CLOUD_IMPORT
import XCTest
import WhoopStore
@testable import StrandImport
@testable import Strand

/// A fetcher that serves canned pages of activity rows and can fail on a chosen page (mimicking an
/// interrupted import). Records the `after` argument it was invoked with.
private final class StubActivityFetcher: StravaActivityFetching {
    var pages: [[[String: Any]]] = []
    var capturedAfter: Int?
    var wasCalled = false
    var throwOnPage: Int?

    func forEachActivityPage(after: Int?,
                             _ handle: (_ rows: [[String: Any]], _ page: Int) async throws -> Void) async throws {
        wasCalled = true
        capturedAfter = after
        var p = 1
        for rows in pages {
            if let t = throwOnPage, p == t { throw StravaError.network("interrupted") }
            try await handle(rows, p)
            p += 1
        }
    }
}

final class StravaSyncCoordinatorTests: XCTestCase {
    private func iso(_ s: String) -> Int { Int(ISO8601DateFormatter().date(from: s)!.timeIntervalSince1970) }
    private func row(_ start: String, _ elapsed: Int = 600, sport: String = "Run") -> [String: Any] {
        ["type": sport, "start_date": start, "elapsed_time": elapsed]
    }

    // MARK: - Cursor arithmetic (pure)

    func testAdvancedCursorIsMonotonic() {
        XCTAssertEqual(StravaSyncCoordinator.advancedCursor(existing: nil, newestSeen: 100), 100)
        XCTAssertEqual(StravaSyncCoordinator.advancedCursor(existing: 100, newestSeen: 50), 100)  // never rewind
        XCTAssertEqual(StravaSyncCoordinator.advancedCursor(existing: 100, newestSeen: 200), 200)
        XCTAssertEqual(StravaSyncCoordinator.advancedCursor(existing: 100, newestSeen: nil), 100)
        XCTAssertNil(StravaSyncCoordinator.advancedCursor(existing: nil, newestSeen: nil))
    }

    func testAfterParameterAppliesLookbackMargin() {
        // Full mode ignores the cursor entirely.
        XCTAssertNil(StravaSyncCoordinator.afterParameter(mode: .full, cursor: 1_700_000_000))
        XCTAssertNil(StravaSyncCoordinator.afterParameter(mode: .incremental, cursor: nil))
        XCTAssertNil(StravaSyncCoordinator.afterParameter(mode: .incremental, cursor: 0))
        // Incremental re-asks from a safe margin BEFORE the cursor (Strava doesn't document whether
        // `after` compares start_date or start_date_local; the overlap is free because writes are upserts).
        XCTAssertEqual(StravaSyncCoordinator.afterParameter(mode: .incremental, cursor: 1_700_000_000),
                       1_700_000_000 - StravaSyncCoordinator.incrementalLookback)
        // Never negative.
        XCTAssertEqual(StravaSyncCoordinator.afterParameter(mode: .incremental, cursor: 100), 0)
        XCTAssertGreaterThanOrEqual(StravaSyncCoordinator.incrementalLookback, 15 * 3600,
                                    "margin must exceed the largest real UTC offset")
    }

    // MARK: - Full backfill: per-page persist, source registered, cursor advanced to newest

    func testFullBackfillPersistsAllPagesAndAdvancesCursor() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubActivityFetcher()
        fetcher.pages = [
            [row("2026-01-05T07:00:00Z"), row("2026-01-04T07:00:00Z")],
            [row("2026-01-03T07:00:00Z")],
        ]
        let coord = StravaSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.sync(mode: .full)

        XCTAssertNil(fetcher.capturedAfter, "full mode ignores the cursor")
        XCTAssertEqual(summary.activities, 3)
        XCTAssertEqual(summary.workouts, 3)
        XCTAssertEqual(summary.pages, 2)

        let rows = try await store.workouts(deviceId: "strava-api", from: 0, to: 9_999_999_999, limit: 100)
        XCTAssertEqual(rows.count, 3)

        // Cursor advanced to the newest activity start (2026-01-05).
        let cursor = try await store.cursor("strava:activities:after")
        XCTAssertEqual(cursor, iso("2026-01-05T07:00:00Z"))
        XCTAssertEqual(summary.newestTs, iso("2026-01-05T07:00:00Z"))

        // Source card registered.
        let devices = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
        XCTAssertEqual(devices.first { $0.id == "strava-api" }?.sourceKind, .cloudImport)
    }

    // MARK: - Incremental uses the stored cursor

    func testIncrementalRequestsActivitiesAfterCursor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setCursor("strava:activities:after", iso("2026-01-04T00:00:00Z"))
        let fetcher = StubActivityFetcher()
        fetcher.pages = [[row("2026-01-05T07:00:00Z")]]
        let coord = StravaSyncCoordinator(fetcher: fetcher, store: store)
        _ = try await coord.sync(mode: .incremental)

        XCTAssertEqual(fetcher.capturedAfter,
                       iso("2026-01-04T00:00:00Z") - StravaSyncCoordinator.incrementalLookback,
                       "incremental fetches from the cursor minus the safety lookback")
        let cursor = try await store.cursor("strava:activities:after")
        XCTAssertEqual(cursor, iso("2026-01-05T07:00:00Z"), "cursor advances to the newest new activity")
    }

    // MARK: - Idempotency across two full runs

    func testTwoFullRunsDoNotDuplicate() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubActivityFetcher()
        fetcher.pages = [[row("2026-01-05T07:00:00Z"), row("2026-01-04T07:00:00Z")]]
        let coord = StravaSyncCoordinator(fetcher: fetcher, store: store)
        _ = try await coord.sync(mode: .full)
        _ = try await coord.sync(mode: .full)   // replay
        let rows = try await store.workouts(deviceId: "strava-api", from: 0, to: 9_999_999_999, limit: 100)
        XCTAssertEqual(rows.count, 2, "a second full run must not duplicate workouts")
    }

    // MARK: - Per-page durability: an interruption keeps completed pages, cursor not advanced

    func testInterruptionKeepsCompletedPagesAndDoesNotAdvanceCursor() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubActivityFetcher()
        fetcher.pages = [
            [row("2026-01-05T07:00:00Z")],   // page 1 persists
            [row("2026-01-06T07:00:00Z")],   // page 2 throws before handling
        ]
        fetcher.throwOnPage = 2
        let coord = StravaSyncCoordinator(fetcher: fetcher, store: store)
        do {
            _ = try await coord.sync(mode: .full)
            XCTFail("expected the interruption to propagate")
        } catch { /* expected */ }

        // Page 1's workout survived the interruption.
        let rows = try await store.workouts(deviceId: "strava-api", from: 0, to: 9_999_999_999, limit: 100)
        XCTAssertEqual(rows.count, 1)
        // Cursor was NOT advanced (a resume re-fetches from the old position).
        let cursor = try await store.cursor("strava:activities:after")
        XCTAssertNil(cursor)
    }
}
#endif // STRAVA_CLOUD_IMPORT
