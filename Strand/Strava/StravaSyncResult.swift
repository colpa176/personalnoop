// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// Counts written during one Strava sync, for the honest import summary shown in the UI. `newestTs` is
/// the latest activity start (unix seconds) seen this run — the value the incremental cursor advances to.
struct StravaSyncSummary: Equatable {
    var activities = 0     // activity summaries parsed from the API
    var workouts = 0       // WorkoutRow upserts that changed a row
    var pages = 0          // activity pages fetched
    var newestTs: Int?     // max activity start ts imported (drives the cursor)
}
#endif // STRAVA_CLOUD_IMPORT
