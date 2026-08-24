// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation
import AuthenticationServices

/// BYO-app OAuth2 authorization-code AuthProvider for Strava. Runs ASWebAuthenticationSession for the
/// interactive consent, exchanges the code for tokens (Keychain), and refreshes on demand. The `session`
/// is injected so the token exchange/refresh POSTs are URLProtocol-testable; the interactive step is
/// integration-only. Conforms to the shared `AuthProvider` seam (Strand/CloudSync). Mirrors
/// OuraOAuthProvider, with the one Strava-specific wrinkle that a refresh may ROTATE the refresh token —
/// whatever the token endpoint returns is re-saved.
final class StravaOAuthProvider: NSObject, AuthProvider, ASWebAuthenticationPresentationContextProviding {
    private let credentials: StravaCredentials
    private let session: URLSession
    private var anchor: ASPresentationAnchor?

    init(credentials: StravaCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    var isConnected: Bool { StravaTokenStore.isConnected }
    func signOut() { StravaTokenStore.clear() }

    func validAccessToken() async throws -> String {
        guard let tokens = StravaTokenStore.load() else { throw StravaError.notConnected }
        if !tokens.isExpired { return tokens.accessToken }
        return try await refreshedAccessToken()
    }

    /// Unconditionally refresh, regardless of the stored token's expiry state. Re-saves the (possibly
    /// rotated) refresh token that Strava returns.
    func refreshedAccessToken() async throws -> String {
        guard let refresh = StravaTokenStore.load()?.refreshToken else { throw StravaError.notConnected }
        let refreshed = try await exchange(StravaOAuth.refreshRequest(credentials: credentials, refreshToken: refresh),
                                           fallbackRefreshToken: refresh)
        guard StravaTokenStore.save(refreshed) else { throw StravaError.tokenExchangeFailed("keychain write failed") }
        return refreshed.accessToken
    }

    @MainActor
    func authorize(presentationAnchor: ASPresentationAnchor) async throws {
        self.anchor = presentationAnchor
        let state = UUID().uuidString
        let url = StravaOAuth.authorizeURL(credentials: credentials, state: state)
        let scheme = URL(string: credentials.redirectURI)?.scheme

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: StravaError.authFailed(err?.localizedDescription ?? "cancelled")) }
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            if !webSession.start() { cont.resume(throwing: StravaError.authFailed("couldn't start web session")) }
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard q["state"] == state else { throw StravaError.authFailed("state mismatch") }
        guard let code = q["code"], !code.isEmpty else { throw StravaError.authFailed(q["error"] ?? "no code") }
        // Strava lets the athlete UNCHECK individual permissions on the consent screen and still approve.
        // The granted set comes back as a comma-delimited `scope`; without the activity-read scope every
        // later API call would 401, so fail here with something actionable instead of storing a dead token.
        guard StravaOAuth.grantsRequiredScope(q["scope"]) else {
            throw StravaError.authFailed("NOOP needs the \"View data about your activities\" permission. "
                                         + "Tap Connect again and leave that box checked.")
        }

        let tokens = try await exchange(StravaOAuth.tokenExchangeRequest(credentials: credentials, code: code))
        guard StravaTokenStore.save(tokens) else { throw StravaError.tokenExchangeFailed("keychain write failed") }
    }

    /// POST a token request and parse the response (shared by exchange + refresh). `fallbackRefreshToken`
    /// is non-nil only on refresh, where a response omitting the refresh token must not drop the one we hold.
    private func exchange(_ req: URLRequest, fallbackRefreshToken: String? = nil) async throws -> StravaTokens {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw StravaError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw StravaError.tokenExchangeFailed("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try StravaOAuth.parseTokenResponse(data, now: Date(), fallbackRefreshToken: fallbackRefreshToken)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
#endif // STRAVA_CLOUD_IMPORT
