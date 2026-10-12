import XCTest
@testable import Strand

/// `PhoneAlertPrefs` — the fork's gate for wrist buzzes on incoming texts and calls: wrist-alerts master,
/// per-kind switch, wrap-aware quiet hours, and the rolling hourly cap on texts (calls are exempt).
final class PhoneAlertPrefsTests: XCTestCase {
    private typealias P = PhoneAlertPrefs

    /// 2026-10-12 12:00:00 UTC, read at UTC so local minute-of-day is 720.
    private let noon = 1_791_806_400

    private func decide(_ kind: P.Kind = .text, at now: Int? = nil, master: Bool = true, kindOn: Bool = true,
                        quiet: Bool = false, quietStart: Int = 22 * 60, quietEnd: Int = 7 * 60,
                        recent: [Int] = [], cap: Int = 3) -> P.Decision {
        P.decide(kind: kind, nowSec: now ?? noon, tzOffsetSec: 0, masterOn: master, kindOn: kindOn,
                 quietOn: quiet, quietStartMin: quietStart, quietEndMin: quietEnd,
                 recentTextBuzzesSec: recent, maxTextsPerHour: cap)
    }

    func testBuzzesWhenEverythingAllows() {
        XCTAssertEqual(decide(), .buzz)
        XCTAssertEqual(decide(.call), .buzz)
    }

    func testMasterAndKindSwitchesGate() {
        XCTAssertEqual(decide(master: false), .masterOff)
        XCTAssertEqual(decide(kindOn: false), .kindOff)
        XCTAssertEqual(decide(.call, master: false), .masterOff)
    }

    func testQuietHoursWrapMidnight() {
        let at2300 = noon + 11 * 3_600
        let at0300 = noon + 15 * 3_600
        let at0700 = noon + 19 * 3_600   // end is exclusive
        XCTAssertEqual(decide(at: at2300, quiet: true), .quietHours)
        XCTAssertEqual(decide(at: at0300, quiet: true), .quietHours)
        XCTAssertEqual(decide(.call, at: at0300, quiet: true), .quietHours)
        XCTAssertEqual(decide(at: at0700, quiet: true), .buzz)
        XCTAssertEqual(decide(quiet: true), .buzz, "noon is outside 22:00–07:00")
        XCTAssertEqual(decide(at: at2300, quiet: false), .buzz, "quiet hours off")
    }

    func testDaytimeQuietWindow() {
        XCTAssertEqual(decide(quiet: true, quietStart: 9 * 60, quietEnd: 17 * 60), .quietHours)
    }

    func testHourlyCapCountsOnlyTheLastHour() {
        let threeRecent = [noon - 60, noon - 600, noon - 3_000]
        XCTAssertEqual(decide(recent: threeRecent, cap: 3), .capReached)
        XCTAssertEqual(decide(recent: threeRecent, cap: 4), .buzz)
        let oneExpired = [noon - 60, noon - 600, noon - 3_600]
        XCTAssertEqual(decide(recent: oneExpired, cap: 3), .buzz, "a buzz exactly an hour old has rolled off")
    }

    func testCallsAreNotCapped() {
        let many = (1...20).map { noon - $0 * 60 }
        XCTAssertEqual(decide(.call, recent: many, cap: 1), .buzz)
    }

    func testEvaluateRecordsTextBuzzesAndEnforcesCap() throws {
        let suite = "PhoneAlertPrefsTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: P.masterKey)
        d.set(2, forKey: P.maxTextsPerHourKey)
        let now = Date(timeIntervalSince1970: TimeInterval(noon))

        XCTAssertEqual(P.evaluate(.text, now: now, d), .buzz)
        XCTAssertEqual(P.evaluate(.text, now: now.addingTimeInterval(10), d), .buzz)
        XCTAssertEqual(P.evaluate(.text, now: now.addingTimeInterval(20), d), .capReached)
        XCTAssertEqual(P.evaluate(.text, now: now.addingTimeInterval(3_601), d), .buzz, "first buzz rolled off")
        XCTAssertEqual(P.evaluate(.call, now: now.addingTimeInterval(30), d), .kindOff, "calls default off")
    }

    func testDefaults() throws {
        let suite = "PhoneAlertPrefsTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(P.textsEnabled(d))
        XCTAssertFalse(P.callsEnabled(d))
        XCTAssertEqual(P.maxTextsPerHour(d), P.defaultMaxTextsPerHour)
        d.set(500, forKey: P.maxTextsPerHourKey)
        XCTAssertEqual(P.maxTextsPerHour(d), P.maxTextsPerHourRange.upperBound)
        XCTAssertEqual(P.evaluate(.text, now: Date(timeIntervalSince1970: TimeInterval(noon)), d), .masterOff,
                       "wrist alerts master defaults off")
    }
}
