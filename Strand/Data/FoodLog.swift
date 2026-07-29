import Foundation
import WhoopStore
import StrandImport

// MARK: - Food log (Repository access)
//
// Storage mirrors the MoodStore pattern: user-authored rows under a DEDICATED source id, so an import
// can never clobber them and they can never clobber an import.
//
// Two layers, joined here:
//   • `foodLogEntry` (v33) holds the ENTRIES — the text, the time, the per-item macros, and whether the
//     numbers were estimated or typed.
//   • `metricSeries` holds the DAILY TOTALS, under the SAME four keys the Cronometer/MacroFactor CSV
//     importer already writes (`NutritionCsvImporter.Keys`). Every write re-derives the day's totals and
//     upserts them, so logged food shows up in Explore, Compare and Insights through the path that
//     already exists for imported nutrition — no second model, no new chart plumbing.
//
// The rollup goes under `WhoopStore.foodLogSourceId` ("food-log"), NOT "nutrition-csv": metricSeries
// upserts are latest-wins on (deviceId, day, key), so sharing the id would let a CSV import and a manual
// entry silently overwrite each other's totals for the same day.

extension Repository {

    /// The day key the food log uses for "today" — the same local calendar day the journal and mood
    /// check-in use, so all three agree on when a day starts.
    static func foodLogDayKey(_ date: Date = Date()) -> String { localDayKey(date) }

    // MARK: - Read

    /// One day's entries, oldest first.
    func foodEntries(day: String) async -> [FoodLogEntry] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.foodLogEntries(day: day)) ?? []
    }

    /// One day's summed macros, or nil when nothing has been logged that day.
    func foodTotals(day: String) async -> FoodDayTotals? {
        guard let store = await storeHandle() else { return nil }
        return try? await store.foodDayTotals(day: day)
    }

    /// Per-day totals across an inclusive day range, oldest day first. One grouped read, so the Nutrition
    /// tab's trend graphs don't fan out into a query per day. Days with nothing logged are absent from the
    /// result (never zero rows), so a gap in the trend reads as "nothing logged", not as "ate nothing".
    func foodTotals(from: String, to: String) async -> [FoodDayTotals] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.foodDayTotals(from: from, to: to)) ?? []
    }

    /// The last `days` local day keys, oldest first, ending today — the x-axis the nutrition trends walk.
    /// Shared by the food and hydration series so both graphs cover exactly the same window.
    static func recentDayKeys(_ days: Int, now: Date = Date()) -> [String] {
        guard days > 0 else { return [] }
        let cal = Calendar.current
        return (0..<days).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: now).map { localDayKey($0) }
        }
    }

    // MARK: - Write

    /// Save (or edit) one entry, then re-derive and publish that day's totals.
    ///
    /// Returns false only when the store could not be opened — the caller surfaces that rather than
    /// letting a tap look like it worked. Note the entry is stored even when it carries no numbers at
    /// all: "I ate this, I don't know the macros" is a legitimate log, it simply adds nothing to totals.
    @discardableResult
    func saveFoodEntry(_ entry: FoodLogEntry) async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            try await store.upsertFoodLogEntry(entry)
        } catch {
            return false
        }
        await publishFoodTotals(day: entry.day, store: store)
        await refresh()
        return true
    }

    /// Delete one entry and re-derive that day's totals.
    @discardableResult
    func deleteFoodEntry(id: String, day: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        let removed = (try? await store.deleteFoodLogEntry(id: id)) ?? false
        guard removed else { return false }
        await publishFoodTotals(day: day, store: store)
        await refresh()
        return true
    }

    // MARK: - Daily rollup

    /// Re-derive `day`'s totals from its entries and upsert them into the metric series under the
    /// food-log source.
    ///
    /// A macro that NO entry recorded is left absent rather than written as 0 — the same rule the column
    /// itself follows. Because metricSeries has no "delete this key for this day" in its upsert path, a
    /// day whose last entry with a given macro is deleted would otherwise keep a stale total, so the
    /// absent case is written as an explicit removal instead.
    private func publishFoodTotals(day: String, store: WhoopStore) async {
        let totals = (try? await store.foodDayTotals(day: day)) ?? nil
        let pairs: [(String, Double?)] = [
            (NutritionCsvImporter.Keys.caloriesIn, totals?.kcal),
            (NutritionCsvImporter.Keys.proteinG, totals?.proteinG),
            (NutritionCsvImporter.Keys.carbsG, totals?.carbsG),
            (NutritionCsvImporter.Keys.fatG, totals?.fatG),
        ]

        var present: [MetricPoint] = []
        var absent: [String] = []
        for (key, value) in pairs {
            if let value {
                present.append(MetricPoint(day: day, key: key, value: value))
            } else {
                absent.append(key)
            }
        }

        if !present.isEmpty {
            _ = try? await store.upsertMetricSeries(present, deviceId: WhoopStore.foodLogSourceId)
        }
        if !absent.isEmpty {
            _ = try? await store.deleteMetricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                    day: day, keys: absent)
        }
    }
}
