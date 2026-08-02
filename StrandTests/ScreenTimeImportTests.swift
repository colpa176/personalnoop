import XCTest
import WhoopStore
@testable import Strand

/// The `noop://import-screentime` deep link — the receiving end of the Shortcut a strap double-tap can
/// fire. Pins the URL validation (a custom scheme is forgeable by any app, so a malformed or foreign
/// link must be REFUSED rather than staged) and the same loop-freedom property `ShortcutHealthImportTests`
/// pins for #581: screen time must land under its own source, never the strap's and never Apple's.
final class ScreenTimeImportTests: XCTestCase {

    private func url(minutes: String? = "143", day: String? = "2026-08-01", version: Int? = 1,
                     host: String = "import-screentime", scheme: String = "noop") -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        var items: [URLQueryItem] = []
        if let minutes { items.append(URLQueryItem(name: "minutes", value: minutes)) }
        if let day { items.append(URLQueryItem(name: "day", value: day)) }
        if let version { items.append(URLQueryItem(name: "v", value: String(version))) }
        c.queryItems = items
        return c.url!
    }

    private func pending(_ u: URL) -> ScreenTimeImport.Pending? {
        guard case .success(let p) = ScreenTimeImport.prepare(url: u) else { return nil }
        return p
    }

    private func rejection(_ u: URL) -> String? {
        guard case .failure(.rejected(let why)) = ScreenTimeImport.prepare(url: u) else { return nil }
        return why
    }

    // MARK: - Accepts

    func testAcceptsWellFormedLink() {
        let p = pending(url())
        XCTAssertEqual(p?.minutes, 143)
        XCTAssertEqual(p?.day, "2026-08-01")
    }

    /// A Shortcut computing "hours × 60" emits a decimal; store whole minutes rather than refusing it.
    func testRoundsDecimalMinutes() {
        XCTAssertEqual(pending(url(minutes: "142.6"))?.minutes, 143)
        XCTAssertEqual(pending(url(minutes: "143.0"))?.minutes, 143)
    }

    /// An omitted day means today, so the common Shortcut needs no date formatting at all.
    func testAbsentDayDefaultsToToday() {
        XCTAssertEqual(pending(url(day: nil))?.day, Repository.dayString(Date()))
    }

    /// The version param is optional; only a MISMATCHED version is refused.
    func testAbsentVersionIsAccepted() {
        XCTAssertEqual(pending(url(version: nil))?.minutes, 143)
    }

    func testAcceptsTheDayBoundaryValue() {
        XCTAssertEqual(pending(url(minutes: "1440"))?.minutes, 1440)
    }

    func testAcceptsZero() {
        XCTAssertEqual(pending(url(minutes: "0"))?.minutes, 0)
    }

    // MARK: - Refuses

    func testRejectsForeignScheme() {
        XCTAssertNotNil(rejection(url(scheme: "shortcuts")))
    }

    func testRejectsForeignHost() {
        XCTAssertNotNil(rejection(url(host: "import-health")))
    }

    func testRejectsUnsupportedVersion() {
        XCTAssertNotNil(rejection(url(version: 2)))
    }

    func testRejectsMissingMinutes() {
        XCTAssertNotNil(rejection(url(minutes: nil)))
    }

    func testRejectsNonNumericMinutes() {
        XCTAssertNotNil(rejection(url(minutes: "a while")))
    }

    func testRejectsNegativeMinutes() {
        XCTAssertNotNil(rejection(url(minutes: "-5")))
    }

    /// Above a calendar day's 1440 minutes the value is a malformed link or a SECONDS figure sent where
    /// minutes were expected — refuse it rather than banking a number that would wreck the axis.
    func testRejectsMoreMinutesThanADayHolds() {
        XCTAssertNotNil(rejection(url(minutes: "1441")))
        XCTAssertNotNil(rejection(url(minutes: "8580")))   // 143 minutes sent as seconds
    }

    func testRejectsMalformedDay() {
        XCTAssertNotNil(rejection(url(day: "01-08-2026")))
        XCTAssertNotNil(rejection(url(day: "today")))
    }

    // MARK: - Loop freedom + isolation

    /// The property the #581 review was built around, restated for this lane: the source screen time is
    /// written to must never be a strap or Apple source, so nothing the app exports can re-import it.
    func testTargetSourceIsNeverAStrapOrAppleSource() {
        XCTAssertFalse(ScreenTimeImport.forbiddenSources.contains(ScreenTimeStore.deviceId))
        XCTAssertTrue(ScreenTimeImport.forbiddenSources.contains("my-whoop"))
        XCTAssertTrue(ScreenTimeImport.forbiddenSources.contains("apple-health"))
    }

    /// The dedicated source id must also stay distinct from the OTHER hand-entered local sources, so a
    /// future read path can't confuse screen time with mood or a typed weight.
    func testSourceIdIsDistinctFromTheOtherLocalSources() {
        XCTAssertNotEqual(ScreenTimeStore.deviceId, MoodStore.moodDeviceId)
        XCTAssertNotEqual(ScreenTimeStore.deviceId, ManualWeightStore.deviceId)
    }

    /// The catalog entry must resolve to the same (key, source) the import writes — otherwise the detail
    /// page reads an empty series while rows pile up under a different id.
    func testCatalogEntryMatchesTheWrittenKeyAndSource() {
        let m = MetricCatalog.metric(key: ScreenTimeStore.key, source: ScreenTimeStore.deviceId)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.unit, "min")
        XCTAssertEqual(m?.higherIsBetter, false)
    }
}
