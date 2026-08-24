// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation
import WhoopStore
import StrandImport

/// Maps parsed `StravaActivity` values onto the on-device WhoopStore under `deviceId = "strava-api"` — the
/// cloud sibling of OuraSyncWriter, scoped to just workouts (v1 is activity-only).
///
/// HONEST DATA: NOOP's own computed scores are never touched. Strava writes ONLY the `workout` table; it
/// never writes a `DailyMetric`, so `recovery`/`strain` cannot come from Strava, and `WorkoutRow.strain`
/// is always nil (Strava's relative-effort/suffer-score is deliberately NOT mapped onto NOOP's strain).
/// The source registers as `.cloudImport`, structurally priority-2 in DayOwnerResolver, so it never seizes
/// a WHOOP day.
enum StravaSyncWriter {
    static let source = "strava"

    /// Pure `StravaActivity` → `WorkoutRow` mapping. Natural key on write is (deviceId, startTs, sport),
    /// so re-mapping the same activity yields the same key → an idempotent upsert (no duplicate workouts).
    /// `strain` is ALWAYS nil here — Strava effort never becomes a NOOP strain.
    static func mapToRows(_ activities: [StravaActivity]) -> [WorkoutRow] {
        activities.map { a in
            WorkoutRow(
                startTs: Int(a.start.timeIntervalSince1970),
                endTs: Int(a.end.timeIntervalSince1970),
                sport: a.sport,
                source: source,
                durationS: a.movingTimeS,     // Strava moving_time (pause-excluded)
                energyKcal: a.energyKcal,
                avgHr: a.avgHr,
                maxHr: a.maxHr,
                strain: nil,                  // NEVER a NOOP strain from Strava
                distanceM: a.distanceM,
                zonesJSON: nil,               // v1 fetches no zones/streams
                notes: a.name)
        }
    }

    /// Register the cloud source (idempotent by id). Mirrors OuraSyncWriter's registration: `.cloudImport`
    /// + `.paired` (never `.active` — an import source must not seize the single live-device slot).
    static func registerSource(in store: WhoopStore, deviceId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        let device = PairedDevice(
            id: deviceId, brand: "Strava", model: "Strava (cloud)",
            sourceKind: .cloudImport, capabilities: [], status: .paired,
            addedAt: now, lastSeenAt: now)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(device)
    }

    /// Upsert one batch of activities as workouts. Returns the number of rows changed. Idempotent by the
    /// workout natural key, so replaying an already-saved batch is a harmless overwrite.
    @discardableResult
    static func persist(_ activities: [StravaActivity], into store: WhoopStore, deviceId: String) async throws -> Int {
        let rows = mapToRows(activities)
        guard !rows.isEmpty else { return 0 }
        return try await store.upsertWorkouts(rows, deviceId: deviceId)
    }
}
#endif // STRAVA_CLOUD_IMPORT
