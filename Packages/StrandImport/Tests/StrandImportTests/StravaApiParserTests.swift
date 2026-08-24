import XCTest
@testable import StrandImport

final class StravaApiParserTests: XCTestCase {

    private func epoch(_ iso: String) -> Int { Int(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970) }

    // MARK: - Happy path + unit correctness (meters / seconds / kcal / bpm)

    func testFullActivityMapsAllFields() {
        let acts = StravaApiParser.parseActivities([[
            "id": 123456789012,
            "name": "Morning Run",
            "type": "Run", "sport_type": "Run",
            "start_date": "2026-01-02T07:00:00Z",
            "elapsed_time": 2400,   // 40 min wall clock
            "moving_time": 2100,    // 35 min moving
            "distance": 6200.0,     // meters
            "average_heartrate": 154.6,
            "max_heartrate": 178.0,
            "calories": 410.0,
        ]])
        XCTAssertEqual(acts.count, 1)
        let a = acts[0]
        XCTAssertEqual(a.id, 123456789012)
        XCTAssertEqual(a.name, "Morning Run")
        XCTAssertEqual(a.sport, "run")
        XCTAssertEqual(Int(a.start.timeIntervalSince1970), epoch("2026-01-02T07:00:00Z"))
        // end = start + elapsed_time (wall clock, includes pauses)
        XCTAssertEqual(Int(a.end.timeIntervalSince1970), epoch("2026-01-02T07:00:00Z") + 2400)
        XCTAssertEqual(a.movingTimeS, 2100)        // moving time → durationS on write
        XCTAssertEqual(a.distanceM, 6200)          // meters, unchanged
        XCTAssertEqual(a.avgHr, 154)               // Double bpm truncated to Int
        XCTAssertEqual(a.maxHr, 178)
        XCTAssertEqual(a.energyKcal, 410)
    }

    func testEndUsesElapsedNotMoving() {
        // Real span is elapsed_time; moving_time is shorter (paused). end must reflect elapsed.
        let a = StravaApiParser.parseActivities([[
            "type": "Ride", "start_date": "2026-03-01T10:00:00Z",
            "elapsed_time": 3600, "moving_time": 3000,
        ]])[0]
        XCTAssertEqual(a.end.timeIntervalSince(a.start), 3600)
        XCTAssertEqual(a.movingTimeS, 3000)
    }

    // MARK: - Activity type normalization

    func testSportNormalization() {
        func sport(_ type: String?) -> String {
            StravaApiParser.parseActivities([[
                "start_date": "2026-01-01T00:00:00Z", "elapsed_time": 60, "sport_type": type as Any,
            ]]).first?.sport ?? "<none>"
        }
        XCTAssertEqual(sport("Run"), "run")
        XCTAssertEqual(sport("Ride"), "ride")
        XCTAssertEqual(sport("TrailRun"), "trail run")
        XCTAssertEqual(sport("MountainBikeRide"), "mountain bike ride")
        XCTAssertEqual(sport("WeightTraining"), "weight training")
        XCTAssertEqual(sport("StandUpPaddling"), "stand-up paddling")
        XCTAssertEqual(sport("EBikeRide"), "e-bike ride")
        // Unknown type → generic de-camel fallback, still readable.
        XCTAssertEqual(sport("FooBarBaz"), "foo bar baz")
        XCTAssertEqual(sport("Kitesurf"), "kitesurf")
    }

    func testSportPrefersSportTypeOverLegacyType() {
        let a = StravaApiParser.parseActivities([[
            "type": "Ride", "sport_type": "MountainBikeRide",
            "start_date": "2026-01-01T00:00:00Z", "elapsed_time": 60,
        ]])[0]
        XCTAssertEqual(a.sport, "mountain bike ride")
    }

    func testMissingTypeYieldsWorkout() {
        let a = StravaApiParser.parseActivities([[
            "start_date": "2026-01-01T00:00:00Z", "elapsed_time": 60,
        ]])[0]
        XCTAssertEqual(a.sport, "workout")
    }

    // MARK: - Missing optional fields

    func testMissingOptionalMetricsAreNil() {
        let a = StravaApiParser.parseActivities([[
            "type": "Walk", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": 1800,
            // no distance, HR, or calories
        ]])[0]
        XCTAssertNil(a.distanceM)
        XCTAssertNil(a.avgHr)
        XCTAssertNil(a.maxHr)
        XCTAssertNil(a.energyKcal)
        XCTAssertNil(a.movingTimeS)   // moving_time absent
        XCTAssertEqual(a.sport, "walk")
    }

    func testZeroHeartRateTreatedAsNotMeasured() {
        let a = StravaApiParser.parseActivities([[
            "type": "Run", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": 600,
            "average_heartrate": 0, "max_heartrate": 0,
        ]])[0]
        XCTAssertNil(a.avgHr)   // posInt drops non-positive
        XCTAssertNil(a.maxHr)
    }

    func testMovingTimeFallbackWhenNoElapsed() {
        // Only moving_time present → it bounds the span.
        let a = StravaApiParser.parseActivities([[
            "type": "Run", "start_date": "2026-01-01T06:00:00Z", "moving_time": 1200,
        ]])[0]
        XCTAssertEqual(a.end.timeIntervalSince(a.start), 1200)
        XCTAssertEqual(a.movingTimeS, 1200)
    }

    // MARK: - Timestamps / timezones

    func testTimezoneOffsetStartParsed() {
        // Strava also exposes offset datetimes; parseISOWithOffset must normalize to the same instant.
        let a = StravaApiParser.parseActivities([[
            "type": "Run", "start_date": "2026-01-02T02:00:00-05:00", "elapsed_time": 60,
        ]])[0]
        XCTAssertEqual(Int(a.start.timeIntervalSince1970), epoch("2026-01-02T07:00:00Z"))
    }

    func testFractionalSecondsStartParsed() {
        let a = StravaApiParser.parseActivities([[
            "type": "Run", "start_date": "2026-01-02T07:00:00.500Z", "elapsed_time": 60,
        ]])[0]
        XCTAssertEqual(a.start.timeIntervalSince1970, Double(epoch("2026-01-02T07:00:00Z")) + 0.5, accuracy: 0.001)
    }

    // MARK: - Malformed / partial payloads (must never trap; just skip the bad rows)

    func testMalformedRowsAreSkippedNotCrash() {
        let acts = StravaApiParser.parseActivities([
            [:],                                                                   // empty
            ["type": "Run"],                                                       // no start, no span
            ["type": "Run", "start_date": "not-a-date", "elapsed_time": 60],       // bad date
            ["type": "Run", "start_date": "2026-01-01T06:00:00Z"],                 // no span
            ["type": "Run", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": 0], // non-positive span
            ["type": "Run", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": -30], // negative
            // one good row survives
            ["type": "Run", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": 300],
        ])
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].end.timeIntervalSince(acts[0].start), 300)
    }

    func testWrongTypedValuesDoNotTrap() {
        // Attacker-shaped values: strings where numbers expected, huge/NaN — WearableJSON must absorb them.
        let acts = StravaApiParser.parseActivities([[
            "id": "not-an-int",
            "type": "Run", "start_date": "2026-01-01T06:00:00Z", "elapsed_time": 600,
            "distance": "far", "average_heartrate": "high", "calories": Double.nan,
        ]])
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].id, 0)         // unparseable id → 0 sentinel
        XCTAssertNil(acts[0].distanceM)
        XCTAssertNil(acts[0].avgHr)
        XCTAssertNil(acts[0].energyKcal)      // NaN dropped
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(StravaApiParser.parseActivities([]).isEmpty)
    }
}
