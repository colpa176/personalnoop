// Shared cloud-import OAuth seam. Compiled when EITHER the Oura or the Strava cloud-import lane is
// enabled (each via its own untracked secrets xcconfig). A default build sets neither condition, so
// none of this — and no cloud networking — is compiled: "fully offline" stays a byte-level property of
// the shipped binary. Extracted from the original Oura-only AuthProvider so Oura and Strava share one seam.
#if OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
import Foundation
import AuthenticationServices

/// The auth seam shared by the cloud-import connectors (Oura, Strava). Concrete providers today are
/// `OuraOAuthProvider` / `StravaOAuthProvider` (BYO-app authorization-code); a future backend-mediated
/// provider can replace either without touching that connector's API client or sync layer.
protocol AuthProvider {
    /// True when tokens are stored (connected), regardless of expiry.
    var isConnected: Bool { get }
    /// Return a currently-valid access token, refreshing transparently if the stored one is expired.
    func validAccessToken() async throws -> String
    /// Force an unconditional refresh (regardless of expiry) and return the new access token.
    /// Used when a token was rejected server-side (401) even though it wasn't clock-expired.
    func refreshedAccessToken() async throws -> String
    /// Run the interactive authorization (opens the provider's consent page) and store the resulting tokens.
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws
    /// Forget the stored tokens (disconnect).
    func signOut()
}
#endif // OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
