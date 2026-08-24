// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// User-facing failure reasons for the Strava cloud-import lane, mapped to clear, non-crashing messages.
/// Mirrors OuraError's shape (LocalizedError + errorDescription).
enum StravaError: LocalizedError, Equatable {
    case notConnected
    case authFailed(String)
    case tokenExchangeFailed(String)
    case badResponse(Int, String)
    case rateLimited
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Strava account first."
        case .authFailed(let d):
            return "Strava sign-in didn't complete: \(d)"
        case .tokenExchangeFailed(let d):
            return "Couldn't exchange the Strava authorization code: \(d)"
        case .badResponse(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "Strava returned an error (\(code))\(extra)."
        case .rateLimited:
            return "Strava is rate-limiting requests. Waiting before retrying."
        case .network(let d):
            return "Network problem talking to Strava: \(d)"
        case .decode:
            return "Couldn't read Strava's response."
        }
    }
}
#endif // STRAVA_CLOUD_IMPORT
