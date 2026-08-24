// Shared cloud-import OAuth seam (see CloudAuthProvider.swift for the gating rationale). The
// x-www-form-urlencoded body builder used by both connectors' OAuth token exchange/refresh requests.
#if OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
import Foundation

enum CloudForm {
    /// Build a POST `application/x-www-form-urlencoded` request. Escapes everything but the unreserved
    /// set — crucially '+' (else the server decodes it to a space) and the '&'/'=' separators, so a
    /// base64 client_secret / code / refresh_token value is never silently corrupted (URLComponents
    /// .percentEncodedQuery leaves '+' unescaped, which is exactly the trap this avoids).
    static func request(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        req.httpBody = fields.map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        return req
    }
}
#endif // OURA_CLOUD_IMPORT || STRAVA_CLOUD_IMPORT
