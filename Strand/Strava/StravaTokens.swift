// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// The OAuth tokens for the Strava cloud lane. Strava access tokens are short-lived (~6 h) and carry an
/// absolute `expires_at` (unix seconds) in the token response, stored directly as `expiresAt`. Strava
/// ALWAYS returns a refresh token (and may rotate it on refresh — the provider re-saves it), so unlike
/// Oura's optional refresh token this one is non-optional. `isExpired` applies a 60 s skew so we refresh
/// slightly early rather than mid-request.
struct StravaTokens: Equatable, Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}
#endif // STRAVA_CLOUD_IMPORT
