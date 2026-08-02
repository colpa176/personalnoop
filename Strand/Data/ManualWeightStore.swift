import Foundation
import WhoopStore

// MARK: - ManualWeightStore
//
// Hand-typed body weight, for the case the Weight detail page already explains: the strap has NO
// weight sensor, so a WHOOP export can never fill this metric, and the only wired source is Apple
// Health body mass. That leaves anyone without HealthKit (a Mac, a phone whose scale doesn't write
// to Health, or a user who simply declines the permission) with a permanently empty page.
//
// Storage mirrors MoodStore / the native journal: weight rows live in the existing metric-series
// tall table under a DEDICATED source id, never under `apple-health`. That isolation is the whole
// point — a later Apple Health sync writes its own rows under its own device id and can never
// clobber or clear a value the user typed by hand, and deleting one stream leaves the other intact.
//
// Canonical unit is KILOGRAMS, matching the `weight` MetricDescriptor's declared unit and the
// apple-health rows it merges with, so both streams are directly comparable with no per-row unit
// tagging. Imperial users type pounds; the view converts at the boundary via `UnitFormatter`.
//
// One value per LOCAL day: the table's (deviceId, day, key) upsert makes re-entering a day's weight
// a plain overwrite, so "correct today's number" needs no extra bookkeeping.
enum ManualWeightStore {
    /// Dedicated source id for hand-typed weight rows. Distinct from `apple-health` so a HealthKit
    /// sync and a manual entry are independent streams that merge at read time (manual wins the day).
    static let deviceId = "noop-weight"

    /// metricSeries key. Deliberately the SAME key the apple-health series uses, so the two streams
    /// are the same physiological quantity in the same unit and the resolver can merge them per day.
    static let key = "weight"

    /// Accepted range for a hand-typed value, in kilograms. Wide enough to cover any real adult or
    /// child, tight enough to reject a mistyped unit (a pounds figure entered while set to metric)
    /// or a stray extra digit. Matches the onboarding weight stepper's 30...250 bounds.
    static let plausibleKg: ClosedRange<Double> = 30...250
}

// MARK: - Persistence (Repository extension)

extension Repository {

    /// Full hand-typed weight series in kilograms (day "yyyy-MM-dd"), oldest→newest. One row per
    /// local day by construction (the tall table's primary key dedupes).
    func manualWeightSeries(days: Int = 4000) async -> [(day: String, value: Double)] {
        await series(key: ManualWeightStore.key, source: ManualWeightStore.deviceId, days: days)
    }

    /// The hand-typed weight for one local day in kilograms, nil if none was entered.
    func manualWeight(day: String) async -> Double? {
        guard let store = await storeHandle() else { return nil }
        let pts = (try? await store.metricSeries(deviceId: ManualWeightStore.deviceId,
                                                 key: ManualWeightStore.key,
                                                 from: day, to: day)) ?? []
        return pts.last?.value
    }

    /// Save (or overwrite) a day's hand-typed weight, in kilograms. Returns false when the value is
    /// outside `plausibleKg` or the store is unavailable, so the caller can keep the sheet open and
    /// say so rather than silently dropping the entry.
    @discardableResult
    func saveManualWeight(day: String, kg: Double) async -> Bool {
        guard kg.isFinite, ManualWeightStore.plausibleKg.contains(kg),
              let store = await storeHandle() else { return false }
        // Two decimals: a scale reads to 0.1 kg / 0.2 lb, and rounding here keeps the stored number
        // identical to the one the user saw themselves type instead of a float-noise tail.
        let rounded = (kg * 100).rounded() / 100
        do {
            _ = try await store.upsertMetricSeries(
                [MetricPoint(day: day, key: ManualWeightStore.key, value: rounded)],
                deviceId: ManualWeightStore.deviceId)
        } catch {
            return false
        }
        return true
    }
}
