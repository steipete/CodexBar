import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WaferUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Wafer API key."
        case let .networkError(message):
            "Wafer network error: \(message)"
        case let .apiError(message):
            "Wafer API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Wafer response: \(message)"
        }
    }
}

private struct WaferQuotaResponse: Decodable {
    let included_request_limit: Int
    let included_request_count: Int
    let remaining_included_requests: Int
    let seconds_to_window_end: Int
    let current_period_used_percent: Double
    let window_start: String
    let window_end: String
}

public struct WaferUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.waferUsage)
    private static let quotaURL = URL(string: "https://pass.wafer.ai/v1/inference/quota")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> WaferUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WaferUsageError.missingCredentials
        }

        var request = URLRequest(url: self.quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw WaferUsageError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            self.log.error("Wafer API returned \(response.statusCode): \(body)")
            throw WaferUsageError.apiError("HTTP \(response.statusCode)")
        }

        let quota: WaferQuotaResponse
        do {
            quota = try JSONDecoder().decode(WaferQuotaResponse.self, from: response.data)
        } catch {
            self.log.error("Failed to parse Wafer response: \(error.localizedDescription)")
            throw WaferUsageError.parseFailed(error.localizedDescription)
        }

        var windowMinutes = 300 // fallback to 5 hours
        if let startDate = parseISO8601Date(quota.window_start),
           let endDate = parseISO8601Date(quota.window_end)
        {
            let durationSeconds = endDate.timeIntervalSince(startDate)
            windowMinutes = Int(round(durationSeconds / 60.0))
        }

        return WaferUsageSnapshot(
            limit: quota.included_request_limit,
            count: quota.included_request_count,
            remaining: quota.remaining_included_requests,
            secondsToReset: quota.seconds_to_window_end,
            usedPercent: quota.current_period_used_percent,
            windowMinutes: windowMinutes,
            updatedAt: Date())
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) {
            return date
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: string)
    }
}
