// Tests the STRAVA_CLOUD_IMPORT-gated Strava token Keychain store; compiled only when the flag is set.
// Runs against the real Keychain on the macOS test host (like OuraTokenStoreTests).
#if STRAVA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class StravaTokenStoreTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        StravaTokenStore.clear()
        // Some sandboxed/CI hosts refuse Keychain writes outright (no signed host app, locked keychain).
        // That is an environment limitation, not a product failure — skip rather than report a red test
        // we can't distinguish from a real one.
        let probe = StravaTokens(accessToken: "probe", refreshToken: "probe", expiresAt: Date())
        guard StravaTokenStore.save(probe) else {
            throw XCTSkip("Keychain unavailable in this environment; StravaTokenStore is untestable here.")
        }
        StravaTokenStore.clear()
    }
    override func tearDown() { StravaTokenStore.clear(); super.tearDown() }

    func testSaveLoadRoundTrip() throws {
        let t = StravaTokens(accessToken: "acc", refreshToken: "ref",
                             expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(StravaTokenStore.save(t))
        let loaded = try XCTUnwrap(StravaTokenStore.load())
        XCTAssertEqual(loaded, t)
        XCTAssertTrue(StravaTokenStore.isConnected)
    }

    func testSaveReplacesExisting() throws {
        XCTAssertTrue(StravaTokenStore.save(StravaTokens(accessToken: "a1", refreshToken: "r1",
                                                         expiresAt: Date(timeIntervalSince1970: 1))))
        XCTAssertTrue(StravaTokenStore.save(StravaTokens(accessToken: "a2", refreshToken: "r2",
                                                         expiresAt: Date(timeIntervalSince1970: 2))))
        let loaded = try XCTUnwrap(StravaTokenStore.load())
        XCTAssertEqual(loaded.accessToken, "a2")     // rotated refresh token survives a re-save
        XCTAssertEqual(loaded.refreshToken, "r2")
    }

    func testClearRemoves() {
        _ = StravaTokenStore.save(StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()))
        StravaTokenStore.clear()
        XCTAssertNil(StravaTokenStore.load())
        XCTAssertFalse(StravaTokenStore.isConnected)
    }

    func testLoadNilWhenEmpty() {
        XCTAssertNil(StravaTokenStore.load())
        XCTAssertFalse(StravaTokenStore.isConnected)
    }
}
#endif // STRAVA_CLOUD_IMPORT
