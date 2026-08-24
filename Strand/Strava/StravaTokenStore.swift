// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation
import Security

/// Keychain Services wrapper for the Strava tokens. One generic-password item (JSON-encoded
/// `StravaTokens`) under a fixed service, so tokens never land in UserDefaults, a plist, or on disk in
/// the clear. Mirrors OuraTokenStore exactly (delete-then-add, ThisDeviceOnly Keychain accessibility).
enum StravaTokenStore {
    private static let service = "com.noop.strava"
    private static let account = "oauth-tokens"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the tokens. Returns false if the Keychain write fails (so callers never assume
    /// a token is stored when it isn't).
    @discardableResult
    static func save(_ tokens: StravaTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Load the stored tokens, or nil if none.
    static func load() -> StravaTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(StravaTokens.self, from: data) else { return nil }
        return tokens
    }

    /// Remove any stored tokens.
    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    /// True when tokens are present (regardless of expiry — an expired token is still "connected", it
    /// just needs a refresh).
    static var isConnected: Bool { load() != nil }
}
#endif // STRAVA_CLOUD_IMPORT
