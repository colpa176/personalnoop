// Shared cloud-import OAuth seam (see CloudAuthProvider.swift for the gating rationale). Extracted from
// the original Oura-only ouraPresentationAnchor() so Oura and Strava share one window lookup.
#if OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's key window as an ASPresentationAnchor for ASWebAuthenticationSession. Modeled on
/// DisplayScreenshot's window lookup. Falls back to a bare anchor (the OAuth providers tolerate it).
@MainActor func cloudAuthPresentationAnchor() -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
}
#endif // OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
