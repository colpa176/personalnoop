// Tests the STRAVA_CLOUD_IMPORT-gated Strava import lane; compiled only when the flag is set.
#if STRAVA_CLOUD_IMPORT
import XCTest
import WhoopStore
@testable import StrandImport
@testable import Strand

final class StravaSyncWriterTests: XCTestCase {
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func activity(id: Int = 1, start: String = "2026-01-02T07:00:00Z", elapsed: Double = 2400,
                          moving: Double? = 2100, sport: String = "run", dist: Double? = 6200,
                          avg: Int? = 154, max: Int? = 178, kcal: Double? = 410, name: String? = "Run") -> StravaActivity {
        let s = iso(start)
        return StravaActivity(id: id, start: s, end: s.addingTimeInterval(elapsed), sport: sport, name: name,
                              movingTimeS: moving, distanceM: dist, avgHr: avg, maxHr: max, energyKcal: kcal)
    }

    // MARK: - Pure mapping: NEVER a NOOP strain, correct field mapping

    func testMapToRowsNeverSetsStrainAndMapsFields() {
        let rows = StravaSyncWriter.mapToRows([activity()])
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertNil(r.strain, "Strava must never populate a NOOP strain")
        XCTAssertEqual(r.source, "strava")
        XCTAssertEqual(r.sport, "run")
        XCTAssertEqual(r.startTs, Int(iso("2026-01-02T07:00:00Z").timeIntervalSince1970))
        XCTAssertEqual(r.endTs, r.startTs + 2400)   // end from elapsed
        XCTAssertEqual(r.durationS, 2100)           // moving_time → durationS
        XCTAssertEqual(r.distanceM, 6200)
        XCTAssertEqual(r.avgHr, 154); XCTAssertEqual(r.maxHr, 178)
        XCTAssertEqual(r.energyKcal, 410)
        XCTAssertNil(r.zonesJSON)
        XCTAssertEqual(r.notes, "Run")
    }

    // MARK: - Persist + source registration

    func testPersistWritesWorkoutsAndRegistersCloudSource() async throws {
        let store = try await WhoopStore.inMemory()
        try StravaSyncWriter.registerSource(in: store, deviceId: "strava-api")
        let n = try await StravaSyncWriter.persist([activity(id: 1), activity(id: 2, start: "2026-01-03T07:00:00Z")],
                                                   into: store, deviceId: "strava-api")
        XCTAssertEqual(n, 2)

        let rows = try await store.workouts(deviceId: "strava-api", from: 0, to: 9_999_999_999, limit: 100)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.source == "strava" && $0.strain == nil })

        let devices = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
        let strava = devices.first { $0.id == "strava-api" }
        XCTAssertEqual(strava?.sourceKind, .cloudImport)
        XCTAssertEqual(strava?.status, .paired)
        XCTAssertEqual(strava?.model, "Strava (cloud)")
    }

    // MARK: - Idempotency (re-sync creates no duplicates)

    func testReSyncIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let acts = [activity(id: 1), activity(id: 2, start: "2026-01-03T07:00:00Z")]
        _ = try await StravaSyncWriter.persist(acts, into: store, deviceId: "strava-api")
        _ = try await StravaSyncWriter.persist(acts, into: store, deviceId: "strava-api")   // replay
        let rows = try await store.workouts(deviceId: "strava-api", from: 0, to: 9_999_999_999, limit: 100)
        XCTAssertEqual(rows.count, 2, "replaying the same activities must not duplicate workouts")
    }

    // MARK: - Never writes a DailyMetric (so recovery/strain can't come from Strava)

    func testStravaNeverWritesDailyMetrics() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await StravaSyncWriter.persist([activity()], into: store, deviceId: "strava-api")
        let days = try await store.dailyMetrics(deviceId: "strava-api", from: "2020-01-01", to: "2030-01-01")
        XCTAssertTrue(days.isEmpty, "Strava writes only workouts — never a DailyMetric row")
    }
}
#endif // STRAVA_CLOUD_IMPORT
