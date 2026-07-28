import XCTest
import GRDB
@testable import WhoopStore

final class CoachConversationStoreTests: XCTestCase {

    // MARK: - migration (v32 creates the table with the right PK + index)

    func testV32CreatesCoachTurnTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("coachTurn"))

        let pk = try await store.primaryKeyColumns("coachTurn")
        XCTAssertEqual(pk, ["id"], "the turn's own UUID is the key — a (deviceId, ts) key would drop two turns in one second")

        let cols = try await store.columnNamesForTest(table: "coachTurn")
        for c in ["id", "deviceId", "sessionId", "ts", "role", "text"] {
            XCTAssertTrue(cols.contains(c), "coachTurn missing column \(c)")
        }
    }

    func testV32CreatesTranscriptIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "coachTurn")
        XCTAssertTrue(names.contains("idx_coachTurn_device_ts"),
                      "v32 must create the (deviceId, ts) index the transcript read and the prune both walk")
    }

    func testV32DoesNotDropExistingTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "metricSeries", "dailyMetric", "sleepSession"] {
            XCTAssertTrue(tables.contains(t), "v32 must not drop \(t)")
        }
    }

    // MARK: - append + read back in order

    func testAppendAndReadBackOldestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "a", ts: 100, role: "user", text: "how's my charge?"))
        try await store.appendCoachTurn(turn(id: "b", ts: 101, role: "assistant", text: "trending up"))
        try await store.appendCoachTurn(turn(id: "c", ts: 102, role: "user", text: "and my sleep?"))

        let turns = try await store.coachTurns()
        XCTAssertEqual(turns.map(\.id), ["a", "b", "c"], "reads come back chronological, ready for a transcript")
        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(turns.first?.text, "how's my charge?")
    }

    func testEmptyStoreReadsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let turns = try await store.coachTurns()
        XCTAssertTrue(turns.isEmpty)
        let count = try await store.coachTurnCount()
        XCTAssertEqual(count, 0)
    }

    /// Two turns inside the SAME second must BOTH survive — the regression a (deviceId, ts) key would
    /// have caused (a fast local model answers within the second it was asked).
    func testTwoTurnsInTheSameSecondBothPersist() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "q", ts: 500, role: "user", text: "hi"))
        try await store.appendCoachTurn(turn(id: "r", ts: 500, role: "assistant", text: "hello"))

        let turns = try await store.coachTurns()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.map(\.id)), ["q", "r"])
    }

    /// Re-appending the same id updates in place (a retry after a failed write must not duplicate).
    func testAppendIsIdempotentOnId() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "x", ts: 10, role: "assistant", text: "first"))
        try await store.appendCoachTurn(turn(id: "x", ts: 10, role: "assistant", text: "edited"))

        let turns = try await store.coachTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "edited")
    }

    // MARK: - limit + sessions

    func testLimitReturnsTheMostRecentTurns() async throws {
        let store = try await WhoopStore.inMemory()
        for i in 0..<10 {
            try await store.appendCoachTurn(turn(id: "t\(i)", ts: 1_000 + i, role: "user", text: "m\(i)"))
        }
        let turns = try await store.coachTurns(limit: 3)
        XCTAssertEqual(turns.map(\.id), ["t7", "t8", "t9"], "the newest 3, still oldest-first")
    }

    func testZeroLimitReadsNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "a", ts: 1, role: "user", text: "hi"))
        let turns = try await store.coachTurns(limit: 0)
        XCTAssertTrue(turns.isEmpty)
    }

    func testSessionReadReturnsOnlyThatDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "mon1", sessionId: "2026-07-27", ts: 10, role: "user", text: "monday"))
        try await store.appendCoachTurn(turn(id: "tue1", sessionId: "2026-07-28", ts: 20, role: "user", text: "tuesday"))
        try await store.appendCoachTurn(turn(id: "tue2", sessionId: "2026-07-28", ts: 21, role: "assistant", text: "reply"))

        let tuesday = try await store.coachTurns(sessionId: "2026-07-28")
        XCTAssertEqual(tuesday.map(\.id), ["tue1", "tue2"])
        let monday = try await store.coachTurns(sessionId: "2026-07-27")
        XCTAssertEqual(monday.map(\.id), ["mon1"])
    }

    // MARK: - device isolation

    func testTurnsAreScopedByDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "mine", ts: 1, role: "user", text: "mine"))
        try await store.appendCoachTurn(turn(id: "other", ts: 2, role: "user", text: "other"),
                                        deviceId: "someone-else")

        let mine = try await store.coachTurns()
        XCTAssertEqual(mine.map(\.id), ["mine"])
        let other = try await store.coachTurns(deviceId: "someone-else")
        XCTAssertEqual(other.map(\.id), ["other"])
    }

    // MARK: - retention

    /// The rolling cap drops the OLDEST turns and keeps exactly `coachTurnRetentionRows`.
    func testRetentionCapDropsOldestTurns() async throws {
        let store = try await WhoopStore.inMemory()
        let cap = WhoopStore.coachTurnRetentionRows
        for i in 0..<(cap + 5) {
            try await store.appendCoachTurn(turn(id: "t\(i)", ts: i, role: "user", text: "m\(i)"))
        }
        let count = try await store.coachTurnCount()
        XCTAssertEqual(count, cap)

        let turns = try await store.coachTurns(limit: cap)
        XCTAssertEqual(turns.first?.id, "t5", "the five oldest turns are the ones dropped")
        XCTAssertEqual(turns.last?.id, "t\(cap + 4)")
    }

    /// Pruning one device must not touch another's transcript.
    func testRetentionCapIsPerDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "keep", ts: 0, role: "user", text: "keep me"),
                                        deviceId: "other-device")
        let cap = WhoopStore.coachTurnRetentionRows
        for i in 0..<(cap + 3) {
            try await store.appendCoachTurn(turn(id: "t\(i)", ts: i, role: "user", text: "m\(i)"))
        }
        let other = try await store.coachTurns(deviceId: "other-device")
        XCTAssertEqual(other.map(\.id), ["keep"])
    }

    // MARK: - clear

    func testClearRemovesEverythingForThatDeviceOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendCoachTurn(turn(id: "a", ts: 1, role: "user", text: "a"))
        try await store.appendCoachTurn(turn(id: "b", ts: 2, role: "assistant", text: "b"))
        try await store.appendCoachTurn(turn(id: "c", ts: 3, role: "user", text: "c"), deviceId: "other")

        let removed = try await store.clearCoachTurns()
        XCTAssertEqual(removed, 2)
        let after = try await store.coachTurns()
        XCTAssertTrue(after.isEmpty)
        let other = try await store.coachTurns(deviceId: "other")
        XCTAssertEqual(other.count, 1, "clearing one transcript must not touch another device's")
    }

    func testClearOnEmptyStoreIsHarmless() async throws {
        let store = try await WhoopStore.inMemory()
        let removed = try await store.clearCoachTurns()
        XCTAssertEqual(removed, 0)
    }

    // MARK: - helper

    private func turn(id: String, sessionId: String = "2026-07-28", ts: Int,
                      role: String, text: String) -> CoachTurn {
        CoachTurn(id: id, sessionId: sessionId, ts: ts, role: role, text: text)
    }
}
