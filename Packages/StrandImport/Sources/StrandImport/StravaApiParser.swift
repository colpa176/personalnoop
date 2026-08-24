import Foundation

// MARK: - Strava API v3 document parser (PURE / network-free)
//
// Takes already-fetched JSON activity documents (the StravaAPIClient does the I/O in the app target) and
// maps them to NOOP's normalized StravaActivity. Same discipline as OuraApiParser: crafted-input safe via
// WearableJSON (never traps on missing/NaN/huge/wrong-typed values) and time via WhoopTime. v1 is
// summary-only: it reads exactly the fields `SummaryActivity` carries and never assumes a detail fetch.

public enum StravaApiParser {

    /// Parse a batch of Strava activity documents (`data[]` of `/athlete/activities`) → `StravaActivity`.
    /// A row is skipped only when it has no parseable start time or no positive duration to bound its span
    /// (mirrors OuraApiParser.parseWorkouts requiring a valid, non-empty time span).
    public static func parseActivities(_ docs: [[String: Any]]) -> [StravaActivity] {
        var out: [StravaActivity] = []
        for a in docs {
            guard let start = WhoopTime.parseISOWithOffset(WearableJSON.str(a, "start_date")) else { continue }
            // Prefer elapsed_time (wall-clock span) to fix the end; fall back to moving_time. A row with
            // neither positive value has no bounded span and is dropped.
            let elapsed = WearableJSON.posDbl(a, "elapsed_time")
            let moving = WearableJSON.posDbl(a, "moving_time")
            guard let span = elapsed ?? moving, span > 0 else { continue }
            let end = start.addingTimeInterval(span)

            // sport_type is Strava's newer, finer field (TrailRun, MountainBikeRide, …); type is the
            // legacy coarse field (Run, Ride, …). Prefer the finer one, fall back to the legacy one.
            let sport = normalizeSport(WearableJSON.str(a, "sport_type") ?? WearableJSON.str(a, "type"))

            out.append(StravaActivity(
                id: WearableJSON.int(a, "id") ?? 0,
                start: start,
                end: end,
                sport: sport,
                name: WearableJSON.str(a, "name"),
                movingTimeS: moving,
                distanceM: WearableJSON.posDbl(a, "distance"),          // Strava distance is METERS
                avgHr: WearableJSON.posInt(a, "average_heartrate"),      // Double in JSON; truncated to Int bpm
                maxHr: WearableJSON.posInt(a, "max_heartrate"),
                energyKcal: WearableJSON.posDbl(a, "calories")))         // absent on summaries → nil in v1
        }
        return out
    }

    /// Normalize a Strava activity type to a stable, human-readable, lowercased label for `WorkoutRow.sport`.
    /// A curated map covers the common types; anything unknown is de-camel-cased generically (so a new
    /// Strava type still yields a readable label instead of a raw token). Empty/absent → "workout".
    public static func normalizeSport(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "workout" }
        if let mapped = curated[raw.lowercased()] { return mapped }
        return deCamel(raw)
    }

    /// Curated Strava-type → label map (keys lowercased). Values stay close to Strava's own nouns rather
    /// than inventing semantics (e.g. "Ride" → "ride", not "cycling"); the writer stores them verbatim.
    private static let curated: [String: String] = [
        "run": "run", "trailrun": "trail run", "virtualrun": "virtual run",
        "ride": "ride", "mountainbikeride": "mountain bike ride", "gravelride": "gravel ride",
        "virtualride": "virtual ride", "ebikeride": "e-bike ride", "velomobile": "velomobile",
        "walk": "walk", "hike": "hike", "swim": "swim",
        "workout": "workout", "weighttraining": "weight training", "crossfit": "crossfit",
        "yoga": "yoga", "pilates": "pilates", "elliptical": "elliptical", "stairstepper": "stair stepper",
        "rowing": "rowing", "virtualrow": "virtual row", "kayaking": "kayaking", "canoeing": "canoeing",
        "standuppaddling": "stand-up paddling", "surfing": "surfing", "kitesurf": "kitesurf",
        "windsurf": "windsurf", "sail": "sail", "swimrun": "swimrun",
        "alpineski": "alpine ski", "backcountryski": "backcountry ski", "nordicski": "nordic ski",
        "rollerski": "roller ski", "snowboard": "snowboard", "snowshoe": "snowshoe",
        "iceskate": "ice skate", "inlineskate": "inline skate", "rockclimbing": "rock climbing",
        "golf": "golf", "soccer": "soccer", "tennis": "tennis", "badminton": "badminton",
        "tabletennis": "table tennis", "pickleball": "pickleball", "squash": "squash",
        "racquetball": "racquetball", "handcycle": "handcycle", "wheelchair": "wheelchair",
        "skateboard": "skateboard", "hiit": "hiit",
    ]

    /// Split a CamelCase / PascalCase token into lowercased space-separated words. "StandUpPaddling" →
    /// "stand up paddling"; a token with no case boundaries just lowercases. Runs of capitals (e.g. an
    /// acronym) are kept together.
    private static func deCamel(_ s: String) -> String {
        var words: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                // Start a new word at a lower→upper boundary ("upP" in StandUpPaddling), but keep a run
                // of capitals together (an acronym) until it hands off to a lowercase letter.
                let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                if prev.isLowercase || (prev.isUppercase && nextIsLower) {
                    words.append(current); current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }
}
