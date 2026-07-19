import Foundation

// MARK: - Cached Plan Info (Codable)

public struct WindsurfCachedPlanInfo: Codable, Sendable {
    public let planName: String?
    public let startTimestamp: Int64?
    public let endTimestamp: Int64?
    public let usage: Usage?
    public let quotaUsage: QuotaUsage?

    public struct Usage: Codable, Sendable {
        public let messages: Int?
        public let usedMessages: Int?
        public let remainingMessages: Int?
        public let flowActions: Int?
        public let usedFlowActions: Int?
        public let remainingFlowActions: Int?
        public let flexCredits: Int?
        public let usedFlexCredits: Int?
        public let remainingFlexCredits: Int?
    }

    public struct QuotaUsage: Codable, Sendable {
        public let dailyRemainingPercent: Double?
        public let weeklyRemainingPercent: Double?
        public let dailyResetAtUnix: Int64?
        public let weeklyResetAtUnix: Int64?
    }
}

// MARK: - Errors & Probe

#if os(macOS)

import SQLite3

public enum WindsurfStatusProbeError: LocalizedError, Sendable, Equatable {
    case dbNotFound(String)
    case sqliteFailed(String)
    case noData
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .dbNotFound(path):
            "Windsurf database not found at \(path). Ensure Windsurf is installed and has been launched at least once."
        case let .sqliteFailed(message):
            "SQLite error reading Windsurf data: \(message)"
        case .noData:
            "No plan data found in Windsurf database. Sign in to Windsurf first."
        case let .parseFailed(message):
            "Could not parse Windsurf plan data: \(message)"
        }
    }
}

// MARK: - Probe

public struct WindsurfStatusProbe: Sendable {
    private static let defaultDBPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
    }()

    private static let query = "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;"

    private let dbPath: String

    public init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? Self.defaultDBPath
    }

    public func fetch() throws -> WindsurfCachedPlanInfo {
        guard FileManager.default.fileExists(atPath: self.dbPath) else {
            throw WindsurfStatusProbeError.dbNotFound(self.dbPath)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw WindsurfStatusProbeError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw WindsurfStatusProbeError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_ROW else {
            if stepResult == SQLITE_DONE {
                throw WindsurfStatusProbeError.noData
            }
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw WindsurfStatusProbeError.sqliteFailed(message)
        }

        guard let jsonString = Self.decodeSQLiteValue(stmt: stmt, index: 0) else {
            throw WindsurfStatusProbeError.noData
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw WindsurfStatusProbeError.parseFailed("Invalid UTF-8 encoding")
        }

        do {
            return try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: jsonData)
        } catch {
            throw WindsurfStatusProbeError.parseFailed(error.localizedDescription)
        }
    }

    private static func decodeSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
            // VSCode/Windsurf state.vscdb schema declares value as BLOB;
            // only accept decodes that still parse as JSON to avoid UTF-16 mojibake.
            return self.decodeJSONBlob(data)
        default:
            return nil
        }
    }

    private static func decodeJSONBlob(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let trimmed = decoded.trimmingCharacters(in: .controlCharacters)
            guard let jsonData = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: jsonData)) != nil
            else {
                continue
            }
            return trimmed
        }
        return nil
    }
}

#else

// MARK: - Windsurf (Unsupported)

public enum WindsurfStatusProbeError: LocalizedError, Sendable, Equatable {
    case notSupported

    public var errorDescription: String? {
        "Windsurf is only supported on macOS."
    }
}

public struct WindsurfStatusProbe: Sendable {
    public init(dbPath _: String? = nil) {}

    public func fetch() throws -> WindsurfCachedPlanInfo {
        throw WindsurfStatusProbeError.notSupported
    }
}

#endif

// MARK: - Conversion to UsageSnapshot

extension WindsurfCachedPlanInfo {
    public func toUsageSnapshot() -> UsageSnapshot {
        var primary: RateWindow?
        var secondary: RateWindow?

        if let quota = self.quotaUsage {
            // Primary: daily usage (usedPercent = 100 - dailyRemainingPercent)
            if let daily = quota.dailyRemainingPercent {
                let resetDate = quota.dailyResetAtUnix.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                primary = RateWindow(
                    usedPercent: max(0, min(100, 100 - daily)),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }

            // Secondary: weekly usage
            if let weekly = quota.weeklyRemainingPercent {
                let resetDate = quota.weeklyResetAtUnix.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                secondary = RateWindow(
                    usedPercent: max(0, min(100, 100 - weekly)),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }
        }

        if primary == nil, let usage = self.usage {
            primary = Self.makeUsageWindow(
                used: usage.usedMessages,
                remaining: usage.remainingMessages,
                total: usage.messages,
                unit: "messages")
        }

        if secondary == nil, let usage = self.usage {
            secondary = Self.makeUsageWindow(
                used: usage.usedFlowActions,
                remaining: usage.remainingFlowActions,
                total: usage.flowActions,
                unit: "flow actions")
        }

        // Identity
        var orgDescription: String?
        if let endTimestamp = self.endTimestamp {
            let endDate = Date(timeIntervalSince1970: TimeInterval(endTimestamp) / 1000)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            orgDescription = "Expires \(formatter.string(from: endDate))"
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .windsurf,
            accountEmail: nil,
            accountOrganization: orgDescription,
            loginMethod: self.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: identity)
    }

    private static func makeUsageWindow(
        used rawUsed: Int?,
        remaining rawRemaining: Int?,
        total rawTotal: Int?,
        unit: String) -> RateWindow?
    {
        guard let total = rawTotal, total > 0 else { return nil }
        let inferredUsed = rawUsed ?? rawRemaining.map { max(0, total - $0) }
        guard let used = inferredUsed else { return nil }
        let clampedUsed = max(0, min(total, used))
        let usedPercent = max(0, min(100, Double(clampedUsed) / Double(total) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "\(clampedUsed) / \(total) \(unit)")
    }

    private static func formatResetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let now = Date()
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Expired" }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "Resets in \(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}
