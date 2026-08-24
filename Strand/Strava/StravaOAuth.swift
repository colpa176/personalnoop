// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// Pure (network-free) pieces of the Strava OAuth2 authorization-code flow: URL/request builders and the
/// token-response parser. Unit-tested directly; the interactive step + the actual POST live in
/// StravaOAuthProvider. No PKCE (Strava's flow doesn't offer it), so the exchange carries client_secret.
///
/// Endpoints & rules verified against Strava's current developer docs (developers.strava.com/docs/authentication):
///   • Web authorize endpoint is used (we drive it inside ASWebAuthenticationSession, not the app-to-app
///     `/oauth/mobile/authorize` deep-link flow).
///   • redirect_uri must be WITHIN the app's registered "Authorization Callback Domain"; only `localhost`
///     / `127.0.0.1` are explicitly whitelisted regardless of scheme. NOOP therefore uses a `localhost`
///     host (default `noop://localhost`, overridable via STRAVA_REDIRECT_URI) — the redirect is caught by
///     the already-registered `noop` URL scheme, so nothing ever binds a loopback socket. The user sets
///     their Strava app's Authorization Callback Domain to `localhost`.
enum StravaOAuth {
    static let authorizeEndpoint = URL(string: "https://www.strava.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://www.strava.com/oauth/token")!

    /// Minimum read-only scope to read ALL of the athlete's activities (including private / "Only You").
    /// `activity:read` alone omits private activities; we request no profile or write scopes. Strava
    /// accepts a comma-delimited scope list.
    static let scopes = ["activity:read_all"]

    /// The consent URL to open in ASWebAuthenticationSession. `state` is a caller-generated nonce echoed
    /// back on redirect and verified, to defeat CSRF / stray callbacks. `approval_prompt=auto` reuses an
    /// existing grant when the scopes already match (no needless re-consent).
    static func authorizeURL(credentials: StravaCredentials, state: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: credentials.clientId),
            .init(name: "redirect_uri", value: credentials.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: scopes.joined(separator: ",")),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Token exchange (authorization_code grant). Strava's documented params are client_id, client_secret,
    /// code, grant_type — redirect_uri is NOT required here (unlike Oura's exchange).
    static func tokenExchangeRequest(credentials: StravaCredentials, code: String) -> URLRequest {
        CloudForm.request(tokenEndpoint, [
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
        ])
    }

    static func refreshRequest(credentials: StravaCredentials, refreshToken: String) -> URLRequest {
        CloudForm.request(tokenEndpoint, [
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    /// Parse a token endpoint response. Strava returns `access_token`, `refresh_token`, and an ABSOLUTE
    /// `expires_at` (unix seconds); we use it directly. `now` is injected only for the `expires_in`
    /// fallback so expiry stays deterministic in tests. A response missing either token is an error.
    static func parseTokenResponse(_ data: Data, now: Date) throws -> StravaTokens {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty,
              let refresh = obj["refresh_token"] as? String, !refresh.isEmpty else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw StravaError.tokenExchangeFailed(detail)
        }
        let expiresAt: Date
        if let at = num(obj["expires_at"]) {
            expiresAt = Date(timeIntervalSince1970: at)
        } else {
            let expiresIn = num(obj["expires_in"]) ?? 21_600   // 6 h default
            expiresAt = now.addingTimeInterval(expiresIn)
        }
        return StravaTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    /// Coerce a JSON number (Double | Int | NSNumber) to a finite Double, or nil.
    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        return nil
    }
}
#endif // STRAVA_CLOUD_IMPORT
