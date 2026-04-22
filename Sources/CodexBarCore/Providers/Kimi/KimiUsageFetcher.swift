import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.kimiAPI)

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> KimiUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiAPIError.missingToken
        }

        let url = KimiSettingsReader.codingBaseURL(environment: environment)
            .appending(path: "usages")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi API returned \(httpResponse.statusCode): \(body)")
            switch httpResponse.statusCode {
            case 401, 403:
                throw KimiAPIError.invalidToken
            case 400:
                throw KimiAPIError.invalidRequest("Bad request")
            default:
                throw KimiAPIError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }

        let payload = try Self.parsePayload(data: data)
        return KimiUsageSnapshot(summary: payload.summary, limits: payload.limits, updatedAt: now)
    }

    static func _parsePayloadForTesting(_ data: Data) throws -> KimiUsagePayload {
        try self.parsePayload(data: data)
    }

    private static func parsePayload(data: Data) throws -> KimiUsagePayload {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let payload = json as? [String: Any]
        else {
            throw KimiAPIError.parseFailed("Root JSON is not an object.")
        }

        let summary = self.summaryRow(from: payload["usage"])
        let limits = self.limitRows(from: payload["limits"])
        if summary == nil && limits.isEmpty {
            throw KimiAPIError.parseFailed("No usage rows found.")
        }

        return KimiUsagePayload(summary: summary, limits: limits)
    }

    private static func summaryRow(from raw: Any?) -> KimiUsageRow? {
        guard let map = raw as? [String: Any] else { return nil }
        return self.row(
            from: map,
            defaultLabel: "Weekly limit",
            windowMinutes: nil)
    }

    private static func limitRows(from raw: Any?) -> [KimiUsageRow] {
        guard let items = raw as? [Any] else { return [] }
        var rows: [KimiUsageRow] = []
        rows.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard let map = item as? [String: Any] else { continue }
            let detail = (map["detail"] as? [String: Any]) ?? map
            let window = map["window"] as? [String: Any]
            let label = self.limitLabel(item: map, detail: detail, window: window, index: index)
            let windowMinutes = self.windowMinutes(from: window ?? detail)
            if let row = self.row(from: detail, defaultLabel: label, windowMinutes: windowMinutes) {
                rows.append(row)
            }
        }

        return rows
    }

    private static func row(
        from map: [String: Any],
        defaultLabel: String,
        windowMinutes: Int?) -> KimiUsageRow?
    {
        let limit = self.intValue(map["limit"])
        var used = self.intValue(map["used"])
        if used == nil,
           let remaining = self.intValue(map["remaining"]),
           let limit
        {
            used = max(0, limit - remaining)
        }

        guard used != nil || limit != nil else { return nil }
        return KimiUsageRow(
            label: (map["name"] as? String) ?? (map["title"] as? String) ?? defaultLabel,
            used: used ?? 0,
            limit: limit ?? 0,
            windowMinutes: windowMinutes,
            resetAt: (map["reset_at"] as? String)
                ?? (map["resetAt"] as? String)
                ?? (map["reset_time"] as? String)
                ?? (map["resetTime"] as? String))
    }

    private static func limitLabel(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any]?,
        index: Int) -> String
    {
        for key in ["name", "title", "scope"] {
            if let value = (item[key] as? String) ?? (detail[key] as? String), !value.isEmpty {
                return value
            }
        }

        if let minutes = self.windowMinutes(from: window ?? detail) {
            if minutes >= 60, minutes % 60 == 0 {
                return "\(minutes / 60)h limit"
            }
            return "\(minutes)m limit"
        }

        return "Limit #\(index + 1)"
    }

    private static func windowMinutes(from map: [String: Any]) -> Int? {
        let duration = self.intValue(map["duration"])
        let timeUnit = ((map["timeUnit"] as? String) ?? (map["time_unit"] as? String) ?? "").uppercased()
        guard let duration else { return nil }

        if timeUnit.contains("MINUTE") || timeUnit.isEmpty {
            return duration
        }
        if timeUnit.contains("HOUR") {
            return duration * 60
        }
        if timeUnit.contains("DAY") {
            return duration * 24 * 60
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}
