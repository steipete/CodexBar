import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PoeUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case unauthorized
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Poe API token."
        case let .networkError(message):
            "Poe network error: \(message)"
        case let .apiError(message):
            "Poe API error: \(message)"
        case .unauthorized:
            "Invalid or expired Poe API token."
        case let .parseFailed(message):
            "Failed to parse Poe response: \(message)"
        }
    }
}

public struct PoeUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.poeUsage)
    private static let usageURL = URL(string: "https://api.poe.com/usage/current_balance")!
    private static let historyURL = URL(string: "https://api.poe.com/usage/points_history")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(apiKey: String) async throws -> PoeUsageSnapshot {
        try await self._fetchUsage(apiKey: apiKey, transport: ProviderHTTPClient.shared)
    }

    static func _fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> PoeUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PoeUsageError.missingCredentials
        }

        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await self.perform(request: request, transport: transport)
        let balance = try self.parseSnapshot(data: response.data).currentPointBalance
        // `points_history` is a best-effort supplement; never let an optional
        // history failure cost the user the current balance display.
        let history: PoeUsageHistorySnapshot?
        do {
            history = try await self.fetchHistory(apiKey: trimmed, transport: transport)
        } catch {
            Self.log.error("Poe points_history fetch failed; returning balance only: \(error)")
            history = nil
        }
        return PoeUsageSnapshot(
            currentPointBalance: balance,
            history: history,
            updatedAt: Date())
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> PoeUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    static func _parseHistoryPageForTesting(_ data: Data) throws
        -> (entries: [PoeUsageHistorySnapshot.Entry], nextCursor: String?)
    {
        try self.parseHistoryPage(data: data)
    }

    static func _buildDailyBucketsForTesting(entries: [PoeUsageHistorySnapshot.Entry])
    -> [PoeUsageHistorySnapshot.DailyBucket] {
        self.buildDailyBuckets(entries: entries)
    }

    private static func parseSnapshot(data: Data) throws -> PoeUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoeUsageError.parseFailed("Invalid JSON")
        }

        let balance = self.double(from: root["current_point_balance"])

        return PoeUsageSnapshot(
            currentPointBalance: balance,
            updatedAt: Date())
    }

    private static func fetchHistory(
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> PoeUsageHistorySnapshot?
    {
        var cursor: String?
        var entries: [PoeUsageHistorySnapshot.Entry] = []
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var page = 0

        while page < 5 {
            page += 1
            var components = URLComponents(url: self.historyURL, resolvingAgainstBaseURL: false)
            var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "100")]
            if let cursor, !cursor.isEmpty {
                query.append(URLQueryItem(name: "starting_after", value: cursor))
            }
            components?.queryItems = query
            guard let url = components?.url else {
                throw PoeUsageError.parseFailed("Invalid points_history URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.timeoutSeconds
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let response = try await self.perform(request: request, transport: transport)
            let parsed = try self.parseHistoryPage(data: response.data)
            entries.append(contentsOf: parsed.entries)
            cursor = parsed.nextCursor

            if parsed.entries.last?.createdAt ?? .distantPast < cutoff { break }
            if cursor == nil { break }
        }

        guard !entries.isEmpty else { return nil }
        let filtered = entries.filter { $0.createdAt >= cutoff }
        guard !filtered.isEmpty else { return nil }
        let daily = self.buildDailyBuckets(entries: filtered)
        return PoeUsageHistorySnapshot(entries: filtered, daily: daily, updatedAt: Date())
    }

    private static func buildDailyBuckets(entries: [PoeUsageHistorySnapshot.Entry])
    -> [PoeUsageHistorySnapshot.DailyBucket] {
        var acc: [String: (points: Double, requests: Int, costUSD: Double)] = [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        for entry in entries {
            let key = formatter.string(from: entry.createdAt)
            var row = acc[key] ?? (points: 0, requests: 0, costUSD: 0)
            row.points += max(0, entry.points)
            row.requests += 1
            row.costUSD += max(0, entry.costUSD ?? 0)
            acc[key] = row
        }
        return acc.keys.sorted().map { day in
            let row = acc[day] ?? (0, 0, 0)
            return PoeUsageHistorySnapshot.DailyBucket(
                day: day,
                points: row.points,
                requests: row.requests,
                costUSD: row.costUSD > 0 ? row.costUSD : nil)
        }
    }

    private static func parseHistoryPage(data: Data) throws
        -> (entries: [PoeUsageHistorySnapshot.Entry], nextCursor: String?)
    {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoeUsageError.parseFailed("Invalid history JSON")
        }

        let rawEntries: [[String: Any]] = if let rows = root["data"] as? [[String: Any]] {
            rows
        } else if let rows = root["items"] as? [[String: Any]] {
            rows
        } else if let rows = root["results"] as? [[String: Any]] {
            rows
        } else {
            []
        }

        let entries = rawEntries.compactMap { row -> PoeUsageHistorySnapshot.Entry? in
            guard let createdAt = self
                .date(fromHistoryValue: row["creation_time"] ?? row["timestamp"] ?? row["created_at"])
            else {
                return nil
            }
            let model = (row["bot_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "unknown"
            let usageType = (row["usage_type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "unknown"
            let points = self.double(from: row["cost_points"])
                ?? self.double(from: row["points"])
                ?? self.double(from: row["point_cost"])
                ?? 0
            let costUSD = self.double(from: row["cost_usd"] ?? row["usd"])
            let id = (row["query_id"] as? String)
                ?? (row["message_id"] as? String)
                ?? (row["id"] as? String)
                ?? "\(createdAt.timeIntervalSince1970)-\(model)"
            return PoeUsageHistorySnapshot.Entry(
                id: id,
                createdAt: createdAt,
                model: model.isEmpty ? "unknown" : model,
                usageType: usageType.isEmpty ? "unknown" : usageType,
                points: max(0, points),
                costUSD: costUSD)
        }

        let nextCursor = (root["next_cursor"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let nextCursor, !nextCursor.isEmpty {
            return (entries: entries, nextCursor: nextCursor)
        }
        if let hasMore = root["has_more"] as? Bool, hasMore {
            let fallbackCursor = (rawEntries.last?["query_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let fallbackCursor, !fallbackCursor.isEmpty {
                return (entries: entries, nextCursor: fallbackCursor)
            }
        }
        return (entries: entries, nextCursor: nil)
    }

    private static func date(fromHistoryValue value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return self.date(fromNumericTimestamp: number.doubleValue)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(trimmed) {
                return self.date(fromNumericTimestamp: numeric)
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func date(fromNumericTimestamp raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1_000_000)
        }
        return Date(timeIntervalSince1970: raw)
    }

    private static func perform(
        request: URLRequest,
        transport: any ProviderHTTPTransport) async throws -> ProviderHTTPResponse
    {
        let (data, urlResponse) = try await transport.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw PoeUsageError.networkError("Non-HTTP response")
        }
        let response = ProviderHTTPResponse(data: data, response: httpResponse)
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Poe API returned \(response.statusCode): \(body)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw PoeUsageError.unauthorized
            }
            throw PoeUsageError.apiError("HTTP \(response.statusCode)")
        }
        return response
    }

    // MARK: - Value parsing

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? raw : nil
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }
}
