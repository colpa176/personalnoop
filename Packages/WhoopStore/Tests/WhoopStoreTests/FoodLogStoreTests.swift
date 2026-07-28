import XCTest
import GRDB
@testable import WhoopStore

final class FoodLogStoreTests: XCTestCase {

    // MARK: - migration

    func testV33CreatesFoodLogEntryTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("foodLogEntry"))

        let pk = try await store.primaryKeyColumns("foodLogEntry")
        XCTAssertEqual(pk, ["id"], "re-logging the same meal is a legitimate second entry — text/time can't key it")

        let cols = try await store.columnNamesForTest(table: "foodLogEntry")
        for c in ["id", "deviceId", "day", "ts", "text", "kcal", "proteinG", "carbsG", "fatG", "source"] {
            XCTAssertTrue(cols.contains(c), "foodLogEntry missing column \(c)")
        }
    }

    func testV33CreatesDayIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "foodLogEntry")
        XCTAssertTrue(names.contains("idx_foodLogEntry_device_day_ts"))
    }

    func testV33DoesNotDropExistingTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["metricSeries", "dailyMetric", "coachTurn", "journal", "workout"] {
            XCTAssertTrue(tables.contains(t), "v33 must not drop \(t)")
        }
    }

    // MARK: - write + read

    func testSaveAndReadBackOneDayInTimeOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "b", ts: 200, text: "lunch", kcal: 620))
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 100, text: "breakfast", kcal: 310))

        let rows = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertEqual(rows.map(\.id), ["a", "b"], "oldest first")
        XCTAssertEqual(rows.first?.text, "breakfast")
        XCTAssertEqual(rows.last?.kcal, 620)
    }

    func testEmptyDayReadsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertTrue(rows.isEmpty)
        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertNil(totals, "no entries means no totals — not a row of zeroes")
    }

    func testUpsertIsIdempotentOnIdSoAnEditReplaces() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "x", ts: 10, text: "rice", kcal: 200))
        try await store.upsertFoodLogEntry(entry(id: "x", ts: 10, text: "rice, large", kcal: 400))

        let rows = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "rice, large")
        XCTAssertEqual(rows.first?.kcal, 400)
    }

    func testEntriesAreScopedByDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "mon", day: "2026-07-27", ts: 10, text: "monday", kcal: 100))
        try await store.upsertFoodLogEntry(entry(id: "tue", day: "2026-07-28", ts: 10, text: "tuesday", kcal: 200))

        let tuesday = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertEqual(tuesday.map(\.id), ["tue"])
        let monday = try await store.foodLogEntries(day: "2026-07-27")
        XCTAssertEqual(monday.map(\.id), ["mon"])
    }

    func testRangeReadSpansDaysOldestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", day: "2026-07-26", ts: 1, text: "a", kcal: 1))
        try await store.upsertFoodLogEntry(entry(id: "b", day: "2026-07-28", ts: 1, text: "b", kcal: 1))
        try await store.upsertFoodLogEntry(entry(id: "c", day: "2026-07-30", ts: 1, text: "c", kcal: 1))

        let rows = try await store.foodLogEntries(from: "2026-07-26", to: "2026-07-28")
        XCTAssertEqual(rows.map(\.id), ["a", "b"], "the range is inclusive on both ends")
    }

    // MARK: - totals: absence must survive summing

    func testTotalsSumPresentValues() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 1, text: "a", kcal: 300, proteinG: 20, carbsG: 30, fatG: 10))
        try await store.upsertFoodLogEntry(entry(id: "b", ts: 2, text: "b", kcal: 500, proteinG: 40, carbsG: 50, fatG: 15))

        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.kcal, 800)
        XCTAssertEqual(totals?.proteinG, 60)
        XCTAssertEqual(totals?.carbsG, 80)
        XCTAssertEqual(totals?.fatG, 25)
        XCTAssertEqual(totals?.entryCount, 2)
    }

    /// The behaviour the whole nil-vs-0 discipline exists for: a macro NO entry recorded must total to
    /// nil, not 0. A 0 would be a claim the user never made, and it would be summed into charts as one.
    func testMacroNoEntryRecordedTotalsToNilNotZero() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 1, text: "a", kcal: 300))
        try await store.upsertFoodLogEntry(entry(id: "b", ts: 2, text: "b", kcal: 200))

        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.kcal, 500)
        XCTAssertNil(totals?.proteinG)
        XCTAssertNil(totals?.carbsG)
        XCTAssertNil(totals?.fatG)
    }

    /// A partially-recorded macro sums only the entries that carried it — a missing value contributes
    /// nothing rather than dragging the total down as a zero.
    func testPartiallyRecordedMacroSumsOnlyWhatIsPresent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 1, text: "a", kcal: 300, proteinG: 25))
        try await store.upsertFoodLogEntry(entry(id: "b", ts: 2, text: "b", kcal: 200))

        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.proteinG, 25)
    }

    /// A note with no numbers is still a log — it counts as an entry but contributes nothing.
    func testEntryWithNoNumbersCountsButAddsNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "note", ts: 1, text: "some soup, no idea"))

        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.entryCount, 1)
        XCTAssertTrue(totals?.isEmpty == true)
        XCTAssertNil(totals?.kcal)
    }

    /// An explicit 0 the user DID record is kept and summed — the case that must stay distinguishable
    /// from "not recorded" above.
    func testExplicitZeroIsSummedNotTreatedAsAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 1, text: "black coffee", kcal: 0, fatG: 0))

        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.kcal, 0)
        XCTAssertEqual(totals?.fatG, 0)
        XCTAssertFalse(totals?.isEmpty == true)
    }

    // MARK: - source provenance

    func testSourceRoundTripsSoAnEstimateIsNeverShownAsMeasured() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "ai", ts: 1, text: "a", kcal: 100, source: .ai))
        try await store.upsertFoodLogEntry(entry(id: "man", day: "2026-07-27", ts: 1, text: "b", kcal: 100, source: .manual))

        let ai = try await store.foodLogEntries(day: "2026-07-28").first
        XCTAssertEqual(ai?.source, "ai")
        XCTAssertTrue(ai?.isEstimated == true)
        let manual = try await store.foodLogEntries(day: "2026-07-27").first
        XCTAssertFalse(manual?.isEstimated == true)
    }

    // MARK: - delete

    func testDeleteRemovesOneEntryAndLeavesTheRest() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", ts: 1, text: "a", kcal: 300))
        try await store.upsertFoodLogEntry(entry(id: "b", ts: 2, text: "b", kcal: 200))

        let deleted = try await store.deleteFoodLogEntry(id: "a")
        XCTAssertTrue(deleted)
        let rows = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertEqual(rows.map(\.id), ["b"])
        let totals = try await store.foodDayTotals(day: "2026-07-28")
        XCTAssertEqual(totals?.kcal, 200, "totals follow the deletion")
    }

    func testDeletingAnUnknownIdReportsFalse() async throws {
        let store = try await WhoopStore.inMemory()
        let deleted = try await store.deleteFoodLogEntry(id: "nope")
        XCTAssertFalse(deleted)
    }

    // MARK: - device isolation

    func testEntriesAreScopedByDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "mine", ts: 1, text: "mine", kcal: 1))
        try await store.upsertFoodLogEntry(entry(id: "other", ts: 1, text: "other", kcal: 1),
                                           deviceId: "someone-else")

        let mine = try await store.foodLogEntries(day: "2026-07-28")
        XCTAssertEqual(mine.map(\.id), ["mine"])
        let other = try await store.foodLogEntries(deviceId: "someone-else", day: "2026-07-28")
        XCTAssertEqual(other.map(\.id), ["other"])
    }

    // MARK: - logged days

    func testFoodLogDaysAreDistinctAndNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodLogEntry(entry(id: "a", day: "2026-07-26", ts: 1, text: "a", kcal: 1))
        try await store.upsertFoodLogEntry(entry(id: "b", day: "2026-07-28", ts: 1, text: "b", kcal: 1))
        try await store.upsertFoodLogEntry(entry(id: "c", day: "2026-07-28", ts: 2, text: "c", kcal: 1))

        let days = try await store.foodLogDays()
        XCTAssertEqual(days, ["2026-07-28", "2026-07-26"])
    }

    // MARK: - the rollup's other half: removing a key for a day

    /// `deleteMetricSeries` is what lets a re-derived rollup express "this metric is no longer present
    /// for this day". Without it the last value written would linger as a stale total.
    func testDeleteMetricSeriesRemovesOnlyTheNamedKeysForThatDay() async throws {
        let store = try await WhoopStore.inMemory()
        let src = WhoopStore.foodLogSourceId
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-28", key: "calories_in", value: 500),
            MetricPoint(day: "2026-07-28", key: "protein_g", value: 30),
            MetricPoint(day: "2026-07-27", key: "protein_g", value: 40),
        ], deviceId: src)

        let removed = try await store.deleteMetricSeries(deviceId: src, day: "2026-07-28",
                                                        keys: ["protein_g"])
        XCTAssertEqual(removed, 1)

        let kcal = try await store.metricSeries(deviceId: src, key: "calories_in",
                                                from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(kcal.count, 1, "an untouched key on the same day survives")
        let protein = try await store.metricSeries(deviceId: src, key: "protein_g",
                                                   from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(protein.map(\.day), ["2026-07-27"], "another day's value survives")
    }

    func testDeleteMetricSeriesWithNoKeysIsANoOp() async throws {
        let store = try await WhoopStore.inMemory()
        let removed = try await store.deleteMetricSeries(deviceId: "x", day: "2026-07-28", keys: [])
        XCTAssertEqual(removed, 0)
    }

    // MARK: - helper

    private func entry(id: String, day: String = "2026-07-28", ts: Int, text: String,
                       kcal: Double? = nil, proteinG: Double? = nil,
                       carbsG: Double? = nil, fatG: Double? = nil,
                       source: FoodEntrySource = .manual) -> FoodLogEntry {
        FoodLogEntry(id: id, day: day, ts: ts, text: text,
                     kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                     source: source)
    }
}
