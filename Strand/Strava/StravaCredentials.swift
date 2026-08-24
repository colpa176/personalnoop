// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// The user's own Strava OAuth app credentials, injected at build time via an untracked xcconfig →
/// Info.plist. Absent credentials mean the Connect flow is unavailable (surfaced in the UI). Mirrors
/// OuraCredentials. Strava's client_id is numeric but is carried as a string (it only ever goes into a
/// URL query / form field).
struct StravaCredentials: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    /// Build from an Info-dictionary-shaped map. Returns nil unless all three keys are present and
    /// non-blank (so a build without the xcconfig cleanly disables the lane rather than half-configuring).
    static func from(_ info: [String: Any]) -> StravaCredentials? {
        func nonBlank(_ key: String) -> String? {
            guard let s = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        guard let id = nonBlank("STRAVA_CLIENT_ID"),
              let secret = nonBlank("STRAVA_CLIENT_SECRET"),
              let redirect = nonBlank("STRAVA_REDIRECT_URI") else { return nil }
        return StravaCredentials(clientId: id, clientSecret: secret, redirectURI: redirect)
    }

    /// The live credentials from the app bundle's Info.plist, or nil if not configured.
    static var fromBundle: StravaCredentials? { from(Bundle.main.infoDictionary ?? [:]) }
}
#endif // STRAVA_CLOUD_IMPORT
