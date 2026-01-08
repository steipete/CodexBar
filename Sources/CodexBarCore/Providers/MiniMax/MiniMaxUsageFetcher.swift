import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("minimax-usage")
    private static let codingPlanRemainsURL =
        URL(string: "https://api.minimax.io/v1/coding_plan/remains")!

    public static func fetchUsage(
        apiToken: String,
        now: Date = Date()) async throws -> MiniMaxUsageSnapshot
    {
        guard !apiToken.isEmpty else {
            throw MiniMaxUsageError.invalidCredentials
        }

        var request = URLRequest(url: self.codingPlanRemainsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
    }
}

enum MiniMaxUsageParser {
    static func parseCodingPlanRemains(data: Data, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        let json = try self.decodeJSON(data: data)
        return try self.parseCodingPlanRemains(json: json, now: now)
    }

    static func parseCodingPlanRemains(json: [String: Any], now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        // Unwrap data wrapper if present (API can return data wrapped or direct response)
        var effectiveJSON = json
        if let dataWrapper = json["data"] as? [String: Any] {
            effectiveJSON = dataWrapper
        }

        // Check base_resp for errors (may be at root or inside data wrapper)
        if let base = effectiveJSON["base_resp"] as? [String: Any],
           let status = self.intValue(base["status_code"]),
           status != 0
        {
            let message = (base["status_msg"] as? String) ?? "status_code \(status)"
            let lower = message.lowercased()
            if status == 1004 || lower.contains("cookie") || lower.contains("log in") || lower.contains("login") {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError(message)
        }

        let modelRemains = effectiveJSON["model_remains"] as? [[String: Any]] ?? []
        guard let first = modelRemains.first else {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        let total = self.intValue(first["current_interval_total_count"])
        let remaining = self.intValue(first["current_interval_usage_count"])
        let usedPercent = self.usedPercent(total: total, remaining: remaining)

        let windowMinutes = self.windowMinutes(
            start: self.dateFromEpoch(first["start_time"]),
            end: self.dateFromEpoch(first["end_time"]))

        let resetsAt = self.resetsAt(
            end: self.dateFromEpoch(first["end_time"]),
            remains: self.intValue(first["remains_time"]),
            now: now)

        let planName = self.parsePlanName(root: effectiveJSON)

        if planName == nil, total == nil, usedPercent == nil {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        let currentPrompts: Int?
        if let total, let remaining {
            currentPrompts = max(0, total - remaining)
        } else {
            currentPrompts = nil
        }

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: total,
            currentPrompts: currentPrompts,
            remainingPrompts: remaining,
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    private static func decodeJSON(data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw MiniMaxUsageError.parseFailed("Invalid coding plan response.")
        }
        return dict
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as Int64:
            Int(number)
        case let number as Double:
            Int(number)
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func usedPercent(total: Int?, remaining: Int?) -> Double? {
        guard let total, total > 0, let remaining else { return nil }
        let used = max(0, total - remaining)
        let percent = Double(used) / Double(total) * 100
        return min(100, max(0, percent))
    }

    private static func dateFromEpoch(_ value: Any?) -> Date? {
        guard let raw = self.intValue(value) else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw) / 1000)
        }
        if raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw))
        }
        return nil
    }

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    private static func resetsAt(end: Date?, remains: Int?, now: Date) -> Date? {
        if let end, end > now {
            return end
        }
        guard let remains, remains > 0 else { return nil }
        let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000 : TimeInterval(remains)
        return now.addingTimeInterval(seconds)
    }

    private static func parsePlanName(root: [String: Any]) -> String? {
        let directKeys = [
            "current_subscribe_title",
            "plan_name",
            "combo_title",
            "current_plan_title",
        ]
        for key in directKeys {
            if let value = root[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        if let card = root["current_combo_card"] as? [String: Any],
           let title = card["title"] as? String
        {
            return title
        }
        return nil
    }
}

public enum MiniMaxUsageError: LocalizedError, Sendable, Equatable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "MiniMax API token is invalid or expired."
        case let .networkError(message):
            "MiniMax network error: \(message)"
        case let .apiError(message):
            "MiniMax API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse MiniMax coding plan: \(message)"
        }
    }
}
