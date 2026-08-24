// Compiled ONLY when the STRAVA_CLOUD_IMPORT compilation condition is set (by the untracked
// StravaSecrets.xcconfig — see StravaConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if STRAVA_CLOUD_IMPORT
import Foundation

/// Strava's `X-RateLimit-Limit` / `-Usage` headers, each a "15min,daily" pair. Captured from every
/// response so the coordinator/UI can surface how close we are to the ceiling. nil when absent.
struct StravaRateLimit: Equatable {
    let usage15min: Int?, limit15min: Int?, usageDaily: Int?, limitDaily: Int?

    /// Parse the paired "a,b" header values. Tolerant: any missing/garbled piece is nil.
    static func from(_ http: HTTPURLResponse) -> StravaRateLimit? {
        func pair(_ name: String) -> (Int?, Int?) {
            guard let v = http.value(forHTTPHeaderField: name) else { return (nil, nil) }
            let parts = v.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (parts.count > 0 ? parts[0] : nil, parts.count > 1 ? parts[1] : nil)
        }
        let (l15, lDay) = pair("X-RateLimit-Limit")
        let (u15, uDay) = pair("X-RateLimit-Usage")
        if l15 == nil && lDay == nil && u15 == nil && uDay == nil { return nil }
        return StravaRateLimit(usage15min: u15, limit15min: l15, usageDaily: uDay, limitDaily: lDay)
    }
}

/// Abstracts the paged activity fetch so the coordinator is testable without a live network
/// (StravaAPIClient conforms). Each page's raw rows are handed to `handle` AS SOON as it arrives, so the
/// coordinator can persist per page (interrupt-safe resume).
protocol StravaActivityFetching {
    func forEachActivityPage(after: Int?,
                             _ handle: (_ rows: [[String: Any]], _ page: Int) async throws -> Void) async throws
}

/// The Strava v3 API client. Injected `AuthProvider` supplies the bearer token (refreshing on expiry);
/// injected `session` makes it URLProtocol-testable. Pages `/athlete/activities` by PAGE NUMBER (Strava
/// has no `next_token`), retries 429 with a bounded backoff, and refreshes-once on 401. Networking lives
/// here in the app target by design. v1 fetches activity SUMMARIES only — no detail/stream/zone calls.
final class StravaAPIClient: StravaActivityFetching {
    private let auth: AuthProvider
    private let session: URLSession
    private let backoff: TimeInterval
    private let perPage: Int
    private let baseURL: String
    private let maxPages = 10_000          // runaway guard
    private(set) var lastRateLimit: StravaRateLimit?

    init(auth: AuthProvider, session: URLSession = .shared, backoff: TimeInterval = 2,
         perPage: Int = 200, baseURL: String = "https://www.strava.com/api/v3") {
        self.auth = auth
        self.session = session
        self.backoff = backoff
        self.perPage = perPage
        self.baseURL = baseURL
    }

    /// Fetch the athlete's activity summaries page by page. `after` (unix seconds) requests only activities
    /// whose start is later than that instant (the incremental cursor); nil / 0 fetches the full history.
    /// Stops at the first empty or short (< perPage) page.
    func forEachActivityPage(after: Int?,
                             _ handle: (_ rows: [[String: Any]], _ page: Int) async throws -> Void) async throws {
        var page = 1
        while page <= maxPages {
            var q: [String: String] = ["per_page": "\(perPage)", "page": "\(page)"]
            if let after, after > 0 { q["after"] = "\(after)" }
            let (data, _) = try await getWithRetry(path: "athlete/activities", query: q)
            let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
            if rows.isEmpty { break }
            try await handle(rows, page)
            if rows.count < perPage { break }   // last (partial) page reached
            page += 1
        }
    }

    /// GET with auth + 429-backoff + 401-refresh-once. Returns (body, status).
    private func getWithRetry(path: String, query: [String: String]) async throws -> (Data, Int) {
        for attempt in 0..<3 {
            let token = try await auth.validAccessToken()
            let (data, code) = try await get(path: path, query: query, token: token)
            switch code {
            case 200..<300:
                return (data, code)
            case 429:
                if backoff > 0 { try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000)) }
                continue
            case 401 where attempt == 0:
                _ = try? await auth.refreshedAccessToken()   // force a real refresh; loop-top re-reads the token
                continue
            default:
                throw StravaError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw StravaError.rateLimited
    }

    private func get(path: String, query: [String: String], token: String) async throws -> (Data, Int) {
        var comps = URLComponents(string: "\(baseURL)/\(path)")!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if let rl = StravaRateLimit.from(http) { lastRateLimit = rl }
                return (data, http.statusCode)
            }
            return (data, 0)
        } catch {
            throw StravaError.network(error.localizedDescription)
        }
    }
}
#endif // STRAVA_CLOUD_IMPORT
