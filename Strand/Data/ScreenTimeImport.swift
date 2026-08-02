import Foundation
import WhoopStore

// MARK: - ScreenTimeImport — the `noop://import-screentime` deep link
//
// Daily screen-time minutes, ingested the way `ShortcutHealthImport` (#581) ingests Apple Health: an
// iOS Shortcut the user builds themselves opens a custom URL, the app writes it to the local store, and
// nothing touches the network. There is no Screen Time API that hands a third-party app a numeric daily
// total — DeviceActivity reports render inside an app-extension view the host app cannot read values out
// of — so a Shortcut reading it from an app that DOES expose a Shortcuts action is the only route, and
// the app's job is just to receive the number.
//
// Pairs with the strap's double-tap gesture: Automations → Double-tap → "Run a Shortcut…" already fires
// `shortcuts://run-shortcut?name=<name>` (MacActions.runShortcut), so a double-tap can run the Shortcut
// that reads the number and opens this URL. That half needed no new code; this is the receiving end.
//
//   noop://import-screentime?v=1&day=2026-08-01&minutes=143
//
// PLAIN QUERY PARAMS, not #581's base64 CSV envelope. That envelope exists because the health import
// carries nine metrics plus workout records over many days; screen time is ONE number for ONE day, and a
// base64 step would add a Shortcut action and make a malformed link undebuggable for no benefit. The
// discipline that actually matters is copied exactly: version-gated, strictly validated, staged for
// explicit user confirmation before any write, and written under a dedicated source id.
//
// LOOP-FREEDOM, the same guard #581 was designed around: rows land under `ScreenTimeStore.deviceId`
// ("noop-screentime") and NEVER under a strap or Apple source. Nothing in the app exports that source, so
// there is no path by which a value written here can be re-read and re-imported. `forbiddenSources` and
// its test pin that a future caller cannot repoint this at the strap.
//
// Platform-neutral (no UIKit) so it compiles into the macOS target too; the iOS `.onOpenURL` wiring
// lives in StrandiOS/ and calls `AppModel.handleScreenTimeImportURL(_:)`.
enum ScreenTimeImport {

    static let scheme = "noop"
    static let host = "import-screentime"
    static let versionParam = "v"
    static let dayParam = "day"
    static let minutesParam = "minutes"
    static let supportedVersion = 1

    /// The source ids this import must never write to. Writing to a strap or Apple source is what would
    /// let an exported value round-trip back in; screen time has no business in either timeline anyway.
    static let forbiddenSources: Set<String> = ["my-whoop", "my-whoop-noop", "apple-health"]

    /// Upper bound for a day's minutes. A calendar day holds 1440; anything at or under that is
    /// physically possible (a device left unlocked all day), anything above is a malformed link or a
    /// seconds value sent where minutes were expected, and is rejected rather than stored.
    static let maxMinutesPerDay = 1440

    enum Outcome: Error, Equatable {
        case imported(day: String, minutes: Int)
        case rejected(String)
    }

    /// A validated link, staged for confirmation. Holding the parsed values (not the URL) means the
    /// confirm path cannot re-parse differently from what the alert told the user it would write.
    struct Pending: Equatable {
        let day: String
        let minutes: Int
    }

    // MARK: - URL → Pending

    /// Validate a `noop://import-screentime` URL. Custom URL schemes are forgeable by any app or web
    /// page, so this only ever VALIDATES and stages — the caller must confirm with the user before
    /// `ingest` writes anything.
    static func prepare(url: URL) -> Result<Pending, Outcome> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.rejected("Not a noop:// link."))
        }
        guard url.host?.lowercased() == host else {
            return .failure(.rejected("Unsupported noop:// action."))
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        if let v = params[versionParam], let n = Int(v), n != supportedVersion {
            return .failure(.rejected("Unsupported import version \(n)."))
        }
        guard let rawMinutes = params[minutesParam], !rawMinutes.isEmpty else {
            return .failure(.rejected("No screen-time value."))
        }
        // Accept a decimal (a Shortcut computing hours × 60 easily emits "143.0") but store whole
        // minutes — the source number has nowhere near sub-minute accuracy.
        guard let asDouble = Double(rawMinutes), asDouble.isFinite, asDouble >= 0 else {
            return .failure(.rejected("Screen time wasn't a number."))
        }
        let minutes = Int(asDouble.rounded())
        guard minutes <= maxMinutesPerDay else {
            return .failure(.rejected("Screen time can't exceed \(maxMinutesPerDay) minutes in a day."))
        }
        // An absent day means "today", so the common Shortcut needs no date formatting at all.
        let day = params[dayParam].flatMap { $0.isEmpty ? nil : $0 } ?? Repository.dayString(Date())
        guard ShortcutHealthImport.isValidDay(day) else {
            return .failure(.rejected("Day must look like 2026-08-01."))
        }
        return .success(Pending(day: day, minutes: minutes))
    }

    // MARK: - Pending → store

    /// Write a confirmed value. One row per local day: the tall table's (deviceId, day, key) upsert
    /// makes a re-send for the same day a plain overwrite, which is what a Shortcut run twice in one
    /// evening should do — replace the running total, never double it.
    static func ingest(prepared: Pending, into store: WhoopStore) async -> Outcome {
        precondition(!forbiddenSources.contains(ScreenTimeStore.deviceId),
                     "screen time must never be written to a strap or Apple source")
        do {
            _ = try await store.upsertMetricSeries(
                [MetricPoint(day: prepared.day, key: ScreenTimeStore.key, value: Double(prepared.minutes))],
                deviceId: ScreenTimeStore.deviceId)
        } catch {
            return .rejected("Couldn't save the screen-time value.")
        }
        return .imported(day: prepared.day, minutes: prepared.minutes)
    }
}

// MARK: - ScreenTimeStore

/// Storage constants for daily screen time. A dedicated source id, isolated exactly like
/// `ManualWeightStore` / `MoodStore`: no importer writes here, so nothing can clobber it.
/// (No Repository read accessor here on purpose: the Screen Time detail page resolves through the
/// generic catalog path — `exploreSeries(key:source:)` falls through to `series(...)` for any
/// non-strap source — so a dedicated reader would be an unused second way to fetch the same rows.)
enum ScreenTimeStore {
    static let deviceId = "noop-screentime"
    /// metricSeries key. Minutes per local day.
    static let key = "screen_time"
}
