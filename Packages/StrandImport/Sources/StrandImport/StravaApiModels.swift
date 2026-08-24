import Foundation

// MARK: - Neutral models emitted by StravaApiParser (network-free; the app-target writer maps them to WhoopStore).
//
// Mirrors the OuraApiModels seam: the pure parser turns already-fetched Strava JSON into these normalized
// values, and the app-target StravaSyncWriter maps them onto the existing `workout` table via WorkoutRow.
// No new database model — a Strava activity is a workout.

/// One Strava activity summary (`SummaryActivity`, from `/api/v3/athlete/activities`) → the `workout`
/// table on write. Times are absolute; metric fields are nil when Strava omits them.
///
/// - `end` is `start + elapsed_time` (real wall-clock span, including pauses) so the timeline span is
///   truthful; `movingTimeS` is Strava's active (pause-excluded) duration, mapped to WorkoutRow.durationS.
/// - `energyKcal` is only ever populated from a `calories` field. The summary endpoint does NOT carry
///   `calories` (that lives on the detailed activity, which v1 deliberately does not fetch), so this is
///   normally nil in v1. We never derive it from `kilojoules` (mechanical work ≠ metabolic energy).
public struct StravaActivity: Sendable, Equatable {
    public let id: Int              // Strava activity id (stable; kept for logging/future detail fetch)
    public let start: Date
    public let end: Date
    public let sport: String        // normalized, human-readable (see StravaApiParser.normalizeSport)
    public let name: String?
    public let movingTimeS: Double? // active duration (pause-excluded) → WorkoutRow.durationS
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let energyKcal: Double?

    public init(id: Int, start: Date, end: Date, sport: String, name: String?,
                movingTimeS: Double?, distanceM: Double?, avgHr: Int?, maxHr: Int?, energyKcal: Double?) {
        self.id = id; self.start = start; self.end = end; self.sport = sport; self.name = name
        self.movingTimeS = movingTimeS; self.distanceM = distanceM
        self.avgHr = avgHr; self.maxHr = maxHr; self.energyKcal = energyKcal
    }
}
