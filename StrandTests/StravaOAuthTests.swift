// Tests the STRAVA_CLOUD_IMPORT-gated Strava import lane; compiled only when the flag is set
// (StrandTests shares the app's cloud-import xcconfig, so flag + creds arrive together).
#if STRAVA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class StravaOAuthTests: XCTestCase {
    private let creds = StravaCredentials(clientId: "12345", clientSecret: "sec",
                                          redirectURI: "noop://localhost")

    // MARK: - Authorize URL + state

    func testAuthorizeURLHasRequiredParams() throws {
        let url = StravaOAuth.authorizeURL(credentials: creds, state: "xyz")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "www.strava.com")
        XCTAssertEqual(comps.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "12345")
        XCTAssertEqual(q["redirect_uri"], "noop://localhost")
        XCTAssertEqual(q["state"], "xyz")
        XCTAssertEqual(q["approval_prompt"], "auto")
        XCTAssertEqual(q["scope"], "activity:read_all")
    }

    func testScopeIsMinimalReadOnly() {
        // Exactly the one read-all activity scope; never a write scope.
        XCTAssertEqual(StravaOAuth.scopes, ["activity:read_all"])
        XCTAssertFalse(StravaOAuth.scopes.contains { $0.contains("write") })
    }

    // MARK: - Form encoding

    func testTokenExchangeRequestIsFormPost() throws {
        let req = StravaOAuth.tokenExchangeRequest(credentials: creds, code: "the-code")
        XCTAssertEqual(req.url?.absoluteString, "https://www.strava.com/oauth/token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=the-code"))
        XCTAssertTrue(body.contains("client_id=12345"))
        XCTAssertTrue(body.contains("client_secret=sec"))
    }

    func testFormEncodingEscapesReservedCharacters() throws {
        // A base64-ish secret with '+' and '/' must be percent-escaped so the server never decodes '+'
        // to a space — the exact trap CloudForm guards.
        let c = StravaCredentials(clientId: "1", clientSecret: "a+b/c=d", redirectURI: "noop://localhost")
        let body = String(data: StravaOAuth.refreshRequest(credentials: c, refreshToken: "r+t").httpBody ?? Data(),
                          encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("client_secret=a%2Bb%2Fc%3Dd"))
        XCTAssertTrue(body.contains("refresh_token=r%2Bt"))
        XCTAssertFalse(body.contains("a+b"))   // never a bare '+'
    }

    func testRefreshRequestParams() throws {
        let body = String(data: StravaOAuth.refreshRequest(credentials: creds, refreshToken: "ref").httpBody ?? Data(),
                          encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=ref"))
    }

    // MARK: - Token parsing + expiry

    func testParseTokenResponseUsesAbsoluteExpiresAt() throws {
        // Strava returns an ABSOLUTE expires_at (unix seconds); it wins over expires_in.
        let json = #"{"access_token":"acc","refresh_token":"ref","expires_at":1000000,"expires_in":21600}"#
            .data(using: .utf8)!
        let tokens = try StravaOAuth.parseTokenResponse(json, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertEqual(tokens.refreshToken, "ref")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 1_000_000))
    }

    func testParseTokenResponseFallsBackToExpiresIn() throws {
        let now = Date(timeIntervalSince1970: 500)
        let json = #"{"access_token":"acc","refresh_token":"ref","expires_in":3600}"#.data(using: .utf8)!
        let tokens = try StravaOAuth.parseTokenResponse(json, now: now)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
    }

    func testParseTokenResponseThrowsWithoutAccessToken() {
        let json = #"{"refresh_token":"ref","expires_at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try StravaOAuth.parseTokenResponse(json, now: Date()))
    }

    func testParseTokenResponseThrowsWithoutRefreshToken() {
        // Strava always returns a refresh token; a response lacking one is treated as a failure.
        let json = #"{"access_token":"acc","expires_at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try StravaOAuth.parseTokenResponse(json, now: Date()))
    }

    // MARK: - Granted-scope verification (the athlete can uncheck a permission and still approve)

    func testGrantedScopeVerification() {
        XCTAssertTrue(StravaOAuth.grantsRequiredScope("activity:read_all"))
        XCTAssertTrue(StravaOAuth.grantsRequiredScope("read,activity:read_all"))
        XCTAssertTrue(StravaOAuth.grantsRequiredScope("read activity:read_all"))
        XCTAssertTrue(StravaOAuth.grantsRequiredScope("activity:read_all,read"))
        // Denied / partial grants must NOT pass.
        XCTAssertFalse(StravaOAuth.grantsRequiredScope("read"))
        XCTAssertFalse(StravaOAuth.grantsRequiredScope("activity:read"))   // narrower scope is not enough
        XCTAssertFalse(StravaOAuth.grantsRequiredScope(""))
        XCTAssertFalse(StravaOAuth.grantsRequiredScope("   "))
        XCTAssertFalse(StravaOAuth.grantsRequiredScope(nil))
    }

    // MARK: - Refresh must never discard the refresh token we already hold

    func testRefreshResponseWithoutRefreshTokenKeepsExistingOne() throws {
        let json = #"{"access_token":"new-acc","expires_at":2000000}"#.data(using: .utf8)!
        let tokens = try StravaOAuth.parseTokenResponse(json, now: Date(), fallbackRefreshToken: "kept-ref")
        XCTAssertEqual(tokens.accessToken, "new-acc")
        XCTAssertEqual(tokens.refreshToken, "kept-ref", "an omitted refresh token must not strand the account")
    }

    func testRotatedRefreshTokenWinsOverFallback() throws {
        let json = #"{"access_token":"a","refresh_token":"rotated","expires_at":2000000}"#.data(using: .utf8)!
        let tokens = try StravaOAuth.parseTokenResponse(json, now: Date(), fallbackRefreshToken: "old")
        XCTAssertEqual(tokens.refreshToken, "rotated")
    }

    func testInitialExchangeStillRequiresRefreshToken() {
        // No fallback on the initial exchange → a response lacking a refresh token is an error.
        let json = #"{"access_token":"acc","expires_at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try StravaOAuth.parseTokenResponse(json, now: Date()))
    }

    func testTokenExpiryHasSkew() {
        // isExpired trips 60 s early so we refresh before, not during, a request.
        let almost = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(30))
        XCTAssertTrue(almost.isExpired)
        let fresh = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(fresh.isExpired)
    }
}
#endif // STRAVA_CLOUD_IMPORT
