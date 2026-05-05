import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PerplexityUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.perplexityAPI)
    private static let creditsURL =
        URL(string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")!
    @TaskLocal static var fetchCreditsOverride:
        (@Sendable (String, String, Date) async throws -> PerplexityUsageSnapshot)?

    /// Testing hook: parse a raw JSON response without making network calls.
    public static func _parseResponseForTesting(_ data: Data, now: Date = Date()) throws -> PerplexityUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(PerplexityCreditsResponse.self, from: data)
            return PerplexityUsageSnapshot(response: decoded, now: now)
        } catch {
            throw PerplexityAPIError.parseFailed(error.localizedDescription)
        }
    }

    public static func fetchCredits(
        sessionToken: String,
        cookieName: String = PerplexityCookieHeader.defaultSessionCookieName,
        now: Date = Date()) async throws -> PerplexityUsageSnapshot
    {
        if let override = self.fetchCreditsOverride {
            return try await override(sessionToken, cookieName, now)
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "\(cookieName)=\(sessionToken)",
            forHTTPHeaderField: "Cookie")
        request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.perplexity.ai/account/usage", forHTTPHeaderField: "Referer")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerplexityAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            Self.log.error("Perplexity API returned \(httpResponse.statusCode): \(truncated)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PerplexityAPIError.invalidToken
            }
            throw PerplexityAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoded = try JSONDecoder().decode(PerplexityCreditsResponse.self, from: data)
            let snapshot = PerplexityUsageSnapshot(response: decoded, now: now)
            Self.log.debug(
                "Perplexity credits parsed balance=\(snapshot.balanceCents) totalUsage=\(snapshot.totalUsageCents)")
            return snapshot
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Self.log.error("Perplexity parse failed: \(error) — response: \(preview)")
            throw PerplexityAPIError.parseFailed(error.localizedDescription)
        }
    }
}
