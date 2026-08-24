// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation
import Combine
import AuthenticationServices
import WhoopStore
#if os(iOS)
import UIKit
#endif

/// Drives the Data Sources "Connect Strava" card: connect (OAuth) → one-time full backfill; "Sync latest"
/// (incremental) → new activities since the cursor; disconnect. @MainActor so all @Published mutations are
/// main-thread; the network/import work hops off-main. Mirrors OuraConnectModel, including taking
/// `repo: Repository` as a per-action PARAMETER (SwiftUI populates @EnvironmentObject only after init()).
@MainActor
final class StravaConnectModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    @Published var isConnected = StravaTokenStore.isConnected

    /// True when the BYO-app credentials are present (else the lane is disabled with guidance).
    var isConfigured: Bool { StravaCredentials.fromBundle != nil }

    /// Connect via OAuth, then run a one-time full history backfill.
    func connectAndImport(repo: Repository) {
        guard let creds = StravaCredentials.fromBundle else {
            statusText = "Add your Strava app's client_id/secret to StravaSecrets.xcconfig first."; return
        }
        setBusy(true); statusText = "Connecting to Strava…"
        Task {
            do {
                let provider = StravaOAuthProvider(credentials: creds)
                try await provider.authorize(presentationAnchor: cloudAuthPresentationAnchor())
                isConnected = true
                try await runSync(repo: repo, provider: provider, mode: .full, verb: "Importing your Strava history…")
            } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            setBusy(false)
        }
    }

    /// Incremental sync: pull only activities newer than the stored cursor. Requires an existing connection.
    func syncLatest(repo: Repository) {
        guard let creds = StravaCredentials.fromBundle else { statusText = "Strava isn't configured."; return }
        guard StravaTokenStore.isConnected else { statusText = "Connect your Strava account first."; return }
        setBusy(true); statusText = "Checking Strava for new activities…"
        Task {
            do {
                let provider = StravaOAuthProvider(credentials: creds)
                try await runSync(repo: repo, provider: provider, mode: .incremental, verb: "Syncing new activities…")
            } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            setBusy(false)
        }
    }

    private func runSync(repo: Repository, provider: StravaOAuthProvider,
                         mode: StravaSyncCoordinator.Mode, verb: String) async throws {
        guard let store = await repo.storeHandle() else { fail("No local store."); return }
        statusText = verb
        let client = StravaAPIClient(auth: provider)
        let coord = StravaSyncCoordinator(fetcher: client, store: store)
        let s = try await coord.sync(mode: mode) { [weak self] p in
            Task { @MainActor in self?.statusText = "Imported \(p.workouts) workouts from \(p.pages) page(s)…" }
        }
        await repo.refresh()
        statusText = s.workouts == 0 && mode == .incremental
            ? "Up to date — no new Strava activities."
            : "Imported \(s.workouts) workouts from \(s.activities) activities."
    }

    func disconnect(repo: Repository) {
        busy = true
        Task {
            StravaOAuthProvider(credentials: StravaCredentials.fromBundle
                ?? .init(clientId: "", clientSecret: "", redirectURI: "")).signOut()
            if let store = await repo.storeHandle() {
                do {
                    try await store.deleteAllData(deviceId: StravaSyncCoordinator.deviceId)
                    // Mirror OuraConnectModel: deleteAllData leaves the registry row; archive it so a
                    // data-less "Strava (cloud)" card doesn't linger in DevicesView.
                    try DeviceRegistryStore(dbQueue: store.registryWriter).archive(StravaSyncCoordinator.deviceId)
                    statusText = "Disconnected."
                } catch {
                    statusText = "Disconnected, but couldn't fully clear local Strava data: \(error.localizedDescription)"
                }
                await repo.refresh()
            } else {
                statusText = "Disconnected."
            }
            isConnected = false; busy = false
        }
    }

    private func fail(_ m: String) { statusText = m; setBusy(false) }

    /// Busy also pins the screen awake on iOS: the backfill is a foreground URLSession flow, and an
    /// auto-lock mid-import suspends the app and freezes the run with no error. Always reset on exit.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
    }
}
#endif // STRAVA_CLOUD_IMPORT
