#if os(iOS)
import CallKit
import Foundation

/// Fork (personalnoop): buzz the strap while an incoming call rings.
///
/// `CXCallObserver` reports the phone's own calls (cellular, FaceTime, and VoIP apps that use CallKit)
/// to any app, with no entitlement or permission prompt. It is passive: iOS calls the delegate when a
/// call changes state, so there is no polling and no cost between calls. It only fires while NOOP's
/// process is running, which it normally is in the background because of the strap's
/// bluetooth-central link; if iOS has suspended NOOP at that moment, that call is missed.
///
/// One ringing call gets up to `maxBuzzesPerCall` buzzes, `repeatEverySec` apart, and stops as soon as
/// the call is answered, declined or ends. Gated by `PhoneAlertPrefs` (master, Calls switch, quiet hours).
@MainActor
final class CallAlertObserver: NSObject, CXCallObserverDelegate {
    static let shared = CallAlertObserver()

    static let maxBuzzesPerCall = 3
    static let repeatEverySec: UInt64 = 5

    private let observer = CXCallObserver()
    /// Calls currently ringing (incoming, not yet connected or ended).
    private var ringing = Set<UUID>()
    /// Calls already handled, so a repeated "still ringing" callback doesn't start a second cycle.
    private var handled = Set<UUID>()
    private var started = false

    /// Attach the delegate. Idempotent; called once at launch.
    func start() {
        guard !started else { return }
        started = true
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let id = call.uuid
        let isRinging = !call.isOutgoing && !call.hasConnected && !call.hasEnded
        let isFinished = call.hasEnded
        Task { @MainActor in self.handle(id: id, isRinging: isRinging, isFinished: isFinished) }
    }

    private func handle(id: UUID, isRinging: Bool, isFinished: Bool) {
        if isFinished {
            ringing.remove(id)
            handled.remove(id)
            return
        }
        guard isRinging else {
            ringing.remove(id)   // answered: stop the cycle
            return
        }
        ringing.insert(id)
        guard !handled.contains(id) else { return }
        handled.insert(id)

        let decision = PhoneAlertPrefs.evaluate(.call)
        guard decision == .buzz else {
            if decision != .kindOff && decision != .masterOff {
                AppModel.shared?.live.append(log: AppModel.stamped("Call alert: not buzzed (\(decision))"))
            }
            return
        }
        Task { @MainActor in
            for n in 0..<Self.maxBuzzesPerCall {
                guard self.ringing.contains(id), let model = AppModel.shared else { return }
                if model.live.encryptedBond {
                    model.buzzStrapOnce()
                    if n == 0 { model.live.append(log: AppModel.stamped("Call alert: buzzed for an incoming call")) }
                } else if n == 0 {
                    model.live.append(log: AppModel.stamped("Call alert: strap not connected, so no buzz"))
                }
                try? await Task.sleep(nanoseconds: Self.repeatEverySec * 1_000_000_000)
            }
        }
    }
}
#endif
