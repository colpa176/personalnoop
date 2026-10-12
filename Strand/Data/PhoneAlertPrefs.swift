import Foundation
import StrandAnalytics

/// Fork (personalnoop): wrist buzzes for the phone's own incoming texts and calls, iPhone only.
///
/// iOS gives no app a way to read another app's notifications, so this can't be the Android
/// notification-listener feature. It covers the two cases iOS does expose instead:
///  - **Texts**: a Shortcuts personal automation (Message → Run Immediately) runs the background
///    `BuzzForTextIntent`, which asks this gate before buzzing.
///  - **Calls**: `CallAlertObserver` (CallKit's `CXCallObserver`) sees an incoming call start ringing.
///
/// Both are gated on the shared wrist-alerts master (`notif.masterEnabled`) and the shared quiet-hours
/// window (`notif.quietHours*`, the same keys the inactivity reminder reads). Text buzzes also carry a
/// rolling per-hour cap so a busy group chat can't keep the motor going; a call is one buzz cycle per
/// call, so it is not capped. Plain `UserDefaults`, nonisolated, so any actor can ask.
enum PhoneAlertPrefs {
    static let textsKey = "phoneAlerts.texts"
    static let callsKey = "phoneAlerts.calls"
    static let maxTextsPerHourKey = "phoneAlerts.maxTextsPerHour"
    /// Unix seconds of each text buzz in the last hour (the cap's rolling window).
    static let recentTextBuzzesKey = "phoneAlerts.recentTextBuzzes"

    static let defaultMaxTextsPerHour = 10
    static let maxTextsPerHourRange = 1...30
    static let capWindowSec = 3_600

    // The shared notification gates (written by AutomationsView's Wrist alerts card).
    static let masterKey = "notif.masterEnabled"
    static let quietKey = "notif.quietHoursEnabled"
    static let quietStartKey = "notif.quietStartMinutes"
    static let quietEndKey = "notif.quietEndMinutes"

    enum Kind { case text, call }

    enum Decision: Equatable {
        case buzz
        case masterOff
        case kindOff
        case quietHours
        case capReached
    }

    /// The pure gate. Order matters only for what the strap log reports: master, then the per-kind
    /// switch, then quiet hours, then (texts only) the hourly cap.
    static func decide(kind: Kind,
                       nowSec: Int,
                       tzOffsetSec: Int,
                       masterOn: Bool,
                       kindOn: Bool,
                       quietOn: Bool,
                       quietStartMin: Int,
                       quietEndMin: Int,
                       recentTextBuzzesSec: [Int],
                       maxTextsPerHour: Int) -> Decision {
        guard masterOn else { return .masterOff }
        guard kindOn else { return .kindOff }
        if quietOn {
            let minute = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
            if SedentaryDetector.windowContains(minute, startMin: quietStartMin, endMin: quietEndMin) {
                return .quietHours
            }
        }
        if kind == .text,
           withinWindow(recentTextBuzzesSec, nowSec: nowSec).count >= max(1, maxTextsPerHour) {
            return .capReached
        }
        return .buzz
    }

    /// The buzz times still inside the rolling hour ending at `nowSec`.
    static func withinWindow(_ times: [Int], nowSec: Int) -> [Int] {
        times.filter { $0 > nowSec - capWindowSec && $0 <= nowSec }
    }

    static func textsEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: textsKey) as? Bool ?? true
    }

    static func callsEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: callsKey) as? Bool ?? false
    }

    static func maxTextsPerHour(_ d: UserDefaults = .standard) -> Int {
        let v = d.object(forKey: maxTextsPerHourKey) as? Int ?? defaultMaxTextsPerHour
        return min(max(v, maxTextsPerHourRange.lowerBound), maxTextsPerHourRange.upperBound)
    }

    /// Read the live settings, decide, and when the answer is `.buzz` for a text, record it against the
    /// hourly cap. Recording happens at decision time, before the BLE write, so two automations firing
    /// together can't both slip under the cap.
    static func evaluate(_ kind: Kind, now: Date = Date(), _ d: UserDefaults = .standard) -> Decision {
        let nowSec = Int(now.timeIntervalSince1970)
        let recent = withinWindow(d.array(forKey: recentTextBuzzesKey) as? [Int] ?? [], nowSec: nowSec)
        let decision = decide(
            kind: kind,
            nowSec: nowSec,
            tzOffsetSec: TimeZone.current.secondsFromGMT(for: now),
            masterOn: d.object(forKey: masterKey) as? Bool ?? false,
            kindOn: kind == .text ? textsEnabled(d) : callsEnabled(d),
            quietOn: d.object(forKey: quietKey) as? Bool ?? false,
            quietStartMin: d.object(forKey: quietStartKey) as? Int ?? SedentaryDetector.defaultQuietStartMin,
            quietEndMin: d.object(forKey: quietEndKey) as? Int ?? SedentaryDetector.defaultQuietEndMin,
            recentTextBuzzesSec: recent,
            maxTextsPerHour: maxTextsPerHour(d))
        if kind == .text {
            d.set(decision == .buzz ? recent + [nowSec] : recent, forKey: recentTextBuzzesKey)
        }
        return decision
    }
}
