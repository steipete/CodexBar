import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Persists DeepSeek balance snapshots so the app can derive consumption
/// (spent = baseline − current balance) when the API only exposes a balance.
///
/// The DeepSeek balance endpoint has no "used" field, so per-day and lifetime
/// spend must be inferred from balance deltas. Recharges (balance increases)
/// reset the baseline so a top-up is not mistaken for negative spend.
///
/// Per local day we keep the first and the last observed balance. The first
/// sample anchors "today's starting balance"; the last sample tracks the
/// current balance trend and detects recharges that happened mid-day.
public struct DeepSeekBalanceHistoryStore: @unchecked Sendable {
    public struct DayRecord: Codable, Equatable, Sendable {
        /// Start of the local day (calendar-normalized).
        public let day: Date
        public let firstBalance: Double
        public let firstCapturedAt: Date
        public let lastBalance: Double
        public let lastCapturedAt: Date

        public init(
            day: Date,
            firstBalance: Double,
            firstCapturedAt: Date,
            lastBalance: Double,
            lastCapturedAt: Date)
        {
            self.day = day
            self.firstBalance = firstBalance
            self.firstCapturedAt = firstCapturedAt
            self.lastBalance = lastBalance
            self.lastCapturedAt = lastCapturedAt
        }
    }

    public struct ConsumptionSummary: Equatable, Sendable {
        /// Spend since the most recent recharge baseline (lifetime).
        public let totalSpent: Double?
        /// Spend between the start of the current local day and now.
        public let todaySpent: Double?
        /// Balance at the start of the current local day (before today's spend).
        public let todayStartBalance: Double?
        /// Currency symbol derived from the recorded balance currency.
        public let currency: String

        public init(
            totalSpent: Double?,
            todaySpent: Double?,
            todayStartBalance: Double?,
            currency: String)
        {
            self.totalSpent = totalSpent
            self.todaySpent = todaySpent
            self.todayStartBalance = todayStartBalance
            self.currency = currency
        }

        public static let unavailable = ConsumptionSummary(
            totalSpent: nil,
            todaySpent: nil,
            todayStartBalance: nil,
            currency: "¥")
    }

    private struct Payload: Codable {
        let version: Int
        let accounts: [String: [DayRecord]]

        static let currentVersion = 1
    }

    private static let epsilon = 0.0001
    private let fileURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private let lock = NSLock()

    public init(
        fileURL: URL = Self.defaultURL(),
        fileManager: FileManager = .default,
        calendar: Calendar = .current)
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.calendar = calendar
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("deepseek-balance-history.json")
    }

    // MARK: - Recording

    /// Records a balance sample for the given account key. Per local day only
    /// the first and the last sample are retained; older days are pruned to a
    /// 90-day window.
    public func record(
        balance: Double,
        currency: String,
        accountKey: String,
        at capturedAt: Date = Date())
    {
        guard balance.isFinite, balance >= 0 else { return }
        let key = accountKey.isEmpty ? "default" : accountKey
        self.lock.lock()
        defer { self.lock.unlock() }

        let payload = self.loadLocked() ?? Payload(version: Payload.currentVersion, accounts: [:])
        var days = payload.accounts[key] ?? []
        let dayStart = self.calendar.startOfDay(for: capturedAt)
        var upserted = false
        for index in days.indices where days[index].day == dayStart {
            var record = days[index]
            if capturedAt < record.firstCapturedAt {
                record = DayRecord(
                    day: dayStart,
                    firstBalance: balance,
                    firstCapturedAt: capturedAt,
                    lastBalance: record.lastBalance,
                    lastCapturedAt: record.lastCapturedAt)
            } else {
                record = DayRecord(
                    day: dayStart,
                    firstBalance: record.firstBalance,
                    firstCapturedAt: record.firstCapturedAt,
                    lastBalance: balance,
                    lastCapturedAt: capturedAt)
            }
            days[index] = record
            upserted = true
            break
        }
        if !upserted {
            days.append(DayRecord(
                day: dayStart,
                firstBalance: balance,
                firstCapturedAt: capturedAt,
                lastBalance: balance,
                lastCapturedAt: capturedAt))
        }
        days.sort { $0.day < $1.day }
        // Retain 90 days.
        let cutoff = self.calendar.date(byAdding: .day, value: -90, to: capturedAt) ?? capturedAt
        days.removeAll { $0.day < cutoff }
        var accounts = payload.accounts
        accounts[key] = days
        self.saveLocked(Payload(version: Payload.currentVersion, accounts: accounts))
    }

    // MARK: - Consumption derivation

    public func consumptionSummary(
        for accountKey: String,
        currentBalance: Double,
        currency: String,
        now: Date = Date()) -> ConsumptionSummary
    {
        let key = accountKey.isEmpty ? "default" : accountKey
        self.lock.lock()
        let payload = self.loadLocked()
        self.lock.unlock()
        guard let days = payload?.accounts[key], !days.isEmpty else {
            return .unavailable
        }

        let symbol = currency == "CNY" ? "¥" : "$"

        // Lifetime spend: walk history in time order, reset the baseline on any
        // recharge (balance rising above the current baseline).
        var baseline = days[0].firstBalance
        for record in days {
            if record.lastBalance > baseline + Self.epsilon {
                baseline = record.lastBalance
            }
        }
        let totalSpent = max(0, baseline - currentBalance)

        // Today's spend. Anchor on today's first sample when available; else the
        // previous day's last sample. If the balance rose mid-day (recharge),
        // attribute spend to the post-recharge segment.
        let todayStart = self.calendar.startOfDay(for: now)
        let todayRecord = days.first { $0.day == todayStart }
        let yesterdayRecord = days.last { $0.day < todayStart }
        let todayStartBalance: Double
        if let todayRecord {
            todayStartBalance = todayRecord.firstBalance
        } else if let yesterdayRecord {
            todayStartBalance = yesterdayRecord.lastBalance
        } else {
            todayStartBalance = days[0].firstBalance
        }

        let todaySpent: Double
        if let todayRecord {
            let rechargedToday = todayRecord.lastBalance > todayRecord.firstBalance + Self.epsilon
            if rechargedToday {
                todaySpent = max(0, todayRecord.lastBalance - currentBalance)
            } else {
                todaySpent = max(0, todayRecord.firstBalance - currentBalance)
            }
        } else {
            todaySpent = max(0, todayStartBalance - currentBalance)
        }

        return ConsumptionSummary(
            totalSpent: totalSpent.isFinite ? totalSpent : nil,
            todaySpent: todaySpent.isFinite ? todaySpent : nil,
            todayStartBalance: todayStartBalance.isFinite ? todayStartBalance : nil,
            currency: symbol)
    }

    // MARK: - Persistence

    private func loadLocked() -> Payload? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == Payload.currentVersion
        else {
            return nil
        }
        return payload
    }

    private func saveLocked(_ payload: Payload) {
        do {
            let directory = self.fileURL.deletingLastPathComponent()
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: self.fileURL, options: [.atomic])
            try? self.fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: self.fileURL.path)
        } catch {
            // Best-effort persistence only.
        }
    }
}
