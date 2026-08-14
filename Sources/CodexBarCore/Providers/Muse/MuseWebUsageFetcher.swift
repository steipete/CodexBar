import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Aggregated usage from dev.meta.ai "Team usage" via browser cookies.
// Model API (api.meta.ai) only returns per-request `usage` in chat completions;
// the dashboard at https://dev.meta.ai/usage shows total tokens input/output,
// daily Token usage / Requests charts. This fetcher imports dev.meta.ai cookies
// and probes the dashboard's internal JSON (when reverse-engineered) before
// falling back to the API-key probe.

public enum MuseWebUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "web-usage"))
    private static let dashboardURL = URL(string: "https://dev.meta.ai/usage")!
    /// Guessed internal endpoints — 404 tries next; real is likely GraphQL under dev.meta.ai
    private static let usageAPIPaths = [
        "/api/usage",
        "/api/usage/team",
        "/api/metrics/usage",
        "/api/billing/usage",
    ]

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        for path in self.usageAPIPaths {
            guard let url = URL(string: "https://dev.meta.ai\(path)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://dev.meta.ai/usage", forHTTPHeaderField: "Referer")
            request.setValue("https://dev.meta.ai", forHTTPHeaderField: "Origin")
            let response = try await transport.response(for: request)
            if response.statusCode == 404 { continue }
            guard (200..<300).contains(response.statusCode) else {
                self.log.error("Muse web \(path) returned HTTP \(response.statusCode)")
                throw MuseUsageError.apiError("HTTP \(response.statusCode) at \(path)")
            }
            if let snap = try self.parseUsageAPI(data: response.data) { return snap }
        }

        var htmlRequest = URLRequest(url: self.dashboardURL, timeoutInterval: timeout)
        htmlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        htmlRequest.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        let htmlResponse = try await transport.response(for: htmlRequest)
        guard (200..<300).contains(htmlResponse.statusCode) else {
            if htmlResponse.statusCode == 401 || htmlResponse.statusCode == 403 {
                throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) — invalid dev.meta.ai session")
            }
            throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) at /usage")
        }
        if let snap = try self.parseDashboardHTML(data: htmlResponse.data) { return snap }

        throw MuseUsageError
            .parseFailed("No parseable usage on dev.meta.ai/usage — capture a HAR for the Team usage XHR")
    }

    static func parseUsageAPI(data: Data) throws -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let totalKeys = ["total_tokens", "totalTokens", "total_tokens_used", "total"]
        let inputKeys = ["input_tokens", "inputTokens"]
        let outputKeys = ["output_tokens", "outputTokens"]
        var total: Double?
        var input: Double?
        var output: Double?
        for k in totalKeys {
            if let v = obj[k] as? Double { total = v; break }; if let v = obj[k] as? Int { total = Double(v); break }
        }
        for k in inputKeys {
            if let v = obj[k] as? Double { input = v; break }; if let v = obj[k] as? Int { input = Double(v); break }
        }
        for k in outputKeys {
            if let v = obj[k] as? Double { output = v; break }; if let v = obj[k] as? Int { output = Double(v); break }
        }
        if total == nil, let nested = obj["data"] as? [String: Any] {
            for k in totalKeys {
                if let v = nested[k] as? Double { total = v; break }; if let v = nested[k] as? Int {
                    total = Double(v); break
                }
            }
        }
        guard let t = total ?? (input != nil || output != nil ? (input ?? 0) + (output ?? 0) : nil),
              t > 0 else { return nil }
        let login = "Team usage: \(Int(t)) tokens"
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: login)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    static func parseDashboardHTML(data: Data) throws -> UsageSnapshot? {
        guard let html = String(data: data, encoding: .utf8),
              html.contains("Team usage") || html.contains("total tokens") || html.contains("Token usage")
        else { return nil }
        return nil
    }
}
