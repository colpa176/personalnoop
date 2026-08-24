// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation
import WhoopStore
import StrandImport

/// Drives a Strava activity sync: register the source, page `/athlete/activities` (full history or
/// incremental via the stored cursor), parse → WorkoutRow → persist EACH page before advancing (so an
/// interrupted import resumes safely), then advance the incremental cursor to the newest activity seen.
/// The cloud sibling of OuraSyncCoordinator, scoped to v1's activity-only lane.
final class StravaSyncCoordinator {
    static let deviceId = "strava-api"
    /// Cursor name in the shared `cursors` table: the newest imported activity start (unix seconds). A
    /// later incremental sync requests activities strictly `after` this instant.
    static let cursorName = "strava:activities:after"

    private let fetcher: StravaActivityFetching
    private let store: WhoopStore

    init(fetcher: StravaActivityFetching, store: WhoopStore) {
        self.fetcher = fetcher
        self.store = store
    }

    enum Mode { case full, incremental }

    /// Monotonic cursor: never move backward (a partial/older run must not rewind incremental progress).
    static func advancedCursor(existing: Int?, newestSeen: Int?) -> Int? {
        switch (existing, newestSeen) {
        case let (e?, n?): return max(e, n)
        case (let e?, nil): return e
        case (nil, let n?): return n
        case (nil, nil):    return nil
        }
    }

    @discardableResult
    func sync(mode: Mode, onProgress: @escaping (StravaSyncSummary) -> Void = { _ in }) async throws -> StravaSyncSummary {
        let deviceId = Self.deviceId
        // Register first, so even a connected account with zero activities shows the source card.
        try StravaSyncWriter.registerSource(in: store, deviceId: deviceId)

        let existing = try await store.cursor(Self.cursorName)
        // Full backfill ignores the cursor (after=nil → whole history); incremental starts after it.
        let after: Int? = (mode == .incremental) ? existing : nil

        var summary = StravaSyncSummary()
        var newestSeen: Int? = nil

        try await fetcher.forEachActivityPage(after: after) { rows, page in
            let activities = StravaApiParser.parseActivities(rows)
            summary.activities += activities.count
            summary.pages = page
            // Per-page durability: land this page in SQLite before the next network fetch, so an
            // interruption keeps every completed page. Upserts are idempotent by (deviceId, startTs, sport).
            summary.workouts += try await StravaSyncWriter.persist(activities, into: store, deviceId: deviceId)
            if let maxTs = activities.map({ Int($0.start.timeIntervalSince1970) }).max() {
                newestSeen = max(newestSeen ?? maxTs, maxTs)
            }
            onProgress(summary)
        }

        // Advance the cursor only after the run completes (a mid-run interruption leaves the old cursor,
        // so a resume re-fetches from there — re-importing already-saved pages harmlessly).
        if let advanced = Self.advancedCursor(existing: existing, newestSeen: newestSeen) {
            try await store.setCursor(Self.cursorName, advanced)
        }
        summary.newestTs = newestSeen
        return summary
    }
}
#endif // STRAVA_CLOUD_IMPORT
