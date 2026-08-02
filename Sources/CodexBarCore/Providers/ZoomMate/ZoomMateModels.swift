import Foundation

private func zoomMateDate(fromMilliseconds raw: Int64?) -> Date? {
    guard let raw, raw > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(raw) / 1000)
}

public enum ZoomMateUsageError: LocalizedError, Sendable {
    case noCapture
    case noSession
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCapture:
            "Paste a cURL capture of the HTTPS ZoomMate credits/status request " +
                "(from ai.zoom.us or zoommate.zoom.us)."
        case .noSession:
            "No ZoomMate session is cached and no session cookies were imported from Chrome. " +
                "Sign in to zoommate.zoom.us in Chrome and refresh from CodexBar, or paste a cURL capture."
        case .invalidCredentials:
            "ZoomMate rejected the current credentials. Sign in again in Chrome or paste a fresh cURL capture."
        case let .apiError(message):
            "ZoomMate API error: \(message)"
        case let .parseFailed(message):
            "Could not parse ZoomMate usage: \(message)"
        }
    }
}

/// Decoded shape of `data.credit_status` from
/// `GET https://ai.zoom.us/ai-computer/api/v1/credits/status`. Dates are epoch milliseconds.
public struct ZoomMateCreditStatus: Decodable, Sendable {
    public let budgetCap: Double?
    public let usedCredit: Double?
    public let remainingCredit: Double?
    public let overageCredit: Double?
    public let allowOverage: Bool?
    public let cycleStartDate: Int64?
    public let cycleEndDate: Int64?
    public let isQuotaAvailable: Bool?
    public let isUnlimited: Bool?

    private enum CodingKeys: String, CodingKey {
        case budgetCap = "budget_cap"
        case usedCredit = "used_credit"
        case remainingCredit = "remaining_credit"
        case overageCredit = "overage_credit"
        case allowOverage = "allow_overage"
        case cycleStartDate = "cycle_start_date"
        case cycleEndDate = "cycle_end_date"
        case isQuotaAvailable = "is_quota_available"
        case isUnlimited = "is_unlimited"
    }

    public init(
        budgetCap: Double?,
        usedCredit: Double?,
        remainingCredit: Double?,
        overageCredit: Double?,
        allowOverage: Bool?,
        cycleStartDate: Int64?,
        cycleEndDate: Int64?,
        isQuotaAvailable: Bool?,
        isUnlimited: Bool?)
    {
        self.budgetCap = budgetCap
        self.usedCredit = usedCredit
        self.remainingCredit = remainingCredit
        self.overageCredit = overageCredit
        self.allowOverage = allowOverage
        self.cycleStartDate = cycleStartDate
        self.cycleEndDate = cycleEndDate
        self.isQuotaAvailable = isQuotaAvailable
        self.isUnlimited = isUnlimited
    }
}

public struct ZoomMateUsageSnapshot: Sendable {
    public let creditStatus: ZoomMateCreditStatus
    public let updatedAt: Date

    public init(creditStatus: ZoomMateCreditStatus, updatedAt: Date) {
        self.creditStatus = creditStatus
        self.updatedAt = updatedAt
    }

    /// Implements design D5's credits mapping. `history` is optional and attached only when a
    /// `credits/history` fetch succeeded (design.md D3) — its absence never blocks the primary
    /// credits/status snapshot from being usable.
    public func toUsageSnapshot(
        history: ZoomMateCreditsHistorySnapshot? = nil,
        accountEmail: String? = nil) -> UsageSnapshot
    {
        let budgetCap = self.creditStatus.budgetCap ?? 0
        let usedCredit = self.creditStatus.usedCredit ?? 0
        let isUnlimited = self.creditStatus.isUnlimited ?? false

        let usedPercent: Double = if isUnlimited || budgetCap <= 0 {
            0
        } else {
            min(100, max(0, usedCredit / budgetCap * 100))
        }

        let resetsAt: Date? = (isUnlimited || budgetCap <= 0)
            ? nil
            : zoomMateDate(fromMilliseconds: self.creditStatus.cycleEndDate)

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: "Credits")

        let identity = ProviderIdentitySnapshot(
            providerID: .zoommate,
            accountEmail: accountEmail,
            accountOrganization: nil,
            loginMethod: accountEmail != nil ? "Cookie" : nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            zoommateCreditsHistory: history,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    /// Pacing verdict (design.md D3), delegated to `ZoomMateCreditStatus.pacingVerdict` so both
    /// this snapshot and `ZoomMateCreditsHistorySnapshot` (which carries its own paired
    /// `creditStatus`) can compute the identical verdict without duplicating the algorithm.
    public func pacingVerdict(now: Date = Date()) -> UsagePace? {
        self.creditStatus.pacingVerdict(now: now)
    }
}

extension ZoomMateCreditStatus {
    /// Pacing verdict (design.md D3): reuses `UsagePace`'s generic stage thresholds rather than
    /// reinventing them. ZoomMate's billing cycle has an arbitrary length (not a fixed weekly
    /// cadence), so `windowMinutes` is set to the actual cycle duration in minutes — with
    /// `workDays: nil`, `UsagePace.weekly()`'s workday-aware branch never engages and it reduces
    /// to a plain linear elapsed-fraction-of-cycle comparison, which is exactly what's needed
    /// here despite the "weekly" name.
    public func pacingVerdict(now: Date = Date()) -> UsagePace? {
        guard let budgetCap, budgetCap > 0,
              self.isUnlimited != true,
              let cycleStartMillis = self.cycleStartDate,
              let cycleEndMillis = self.cycleEndDate
        else {
            return nil
        }
        guard let cycleStart = zoomMateDate(fromMilliseconds: cycleStartMillis),
              let cycleEnd = zoomMateDate(fromMilliseconds: cycleEndMillis),
              cycleEnd > cycleStart
        else {
            return nil
        }

        let usedCredit = self.usedCredit ?? 0
        let usedPercent = min(100, max(0, usedCredit / budgetCap * 100))
        let cycleMinutes = Int(cycleEnd.timeIntervalSince(cycleStart) / 60)
        guard cycleMinutes > 0 else { return nil }

        let window = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: cycleMinutes,
            resetsAt: cycleEnd,
            resetDescription: "Credits")
        return UsagePace.weekly(window: window, now: now, workDays: nil)
    }
}

/// One calendar day's total credit consumption, aggregated from raw `credits/history` ledger
/// records. Mirrors `OpenAIDashboardDailyBreakdown`'s shape (`day` as a local `yyyy-MM-dd` key)
/// so the same day-key parsing/formatting used by the Codex credits-history chart applies here
/// unchanged.
public struct ZoomMateCreditDailyBreakdown: Equatable, Sendable {
    /// Day key in `yyyy-MM-dd` (local time).
    public let day: String
    public let totalCreditsUsed: Double

    public init(day: String, totalCreditsUsed: Double) {
        self.day = day
        self.totalCreditsUsed = totalCreditsUsed
    }
}

extension ZoomMateCreditsHistorySnapshot {
    /// Aggregates raw `credits/history` records into a Today/N-day series, one entry per
    /// calendar day (local time) that has at least one qualifying record. `is_deleted` records
    /// are excluded per design.md D3 (they represent removed sessions, not real spend); running
    /// sessions (`is_running == true`) are still counted since their `cost` reflects consumption
    /// so far. Records with an unparseable `time` or a negative `cost` are skipped defensively
    /// rather than corrupting the aggregate.
    ///
    /// Records older than a trailing 30-calendar-day window from `now` are excluded before
    /// bucketing, mirroring `CostUsageFetcher`'s `since = now - (historyDays - 1)` boundary
    /// (design.md D3). This makes the 30-day window an explicit, model-level guarantee rather
    /// than an implicit assumption inherited from the fetcher's request parameters — the result
    /// stays calendar-bounded even if the fetch window, caching, or pagination ever changes.
    public func dailyBreakdown(calendar: Calendar = .current, now: Date = Date()) -> [ZoomMateCreditDailyBreakdown] {
        var totalsByDay: [String: Double] = [:]
        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.calendar = calendar
        dayKeyFormatter.timeZone = calendar.timeZone
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = calendar.date(byAdding: .day, value: -29, to: now) ?? now

        for record in self.records {
            guard record.isDeleted != true else { continue }
            guard let cost = record.cost, cost >= 0 else { continue }
            guard let timeString = record.time else { continue }
            guard let date = isoFormatter.date(from: timeString) ?? isoFormatterNoFraction.date(from: timeString)
            else {
                continue
            }
            guard date >= calendar.startOfDay(for: since) else { continue }
            let dayKey = dayKeyFormatter.string(from: date)
            totalsByDay[dayKey, default: 0] += cost
        }

        return totalsByDay
            .map { ZoomMateCreditDailyBreakdown(day: $0.key, totalCreditsUsed: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// Sum of `cost` for whichever calendar day (local time) is "today" relative to `now`, i.e.
    /// the current-day bucket from `dailyBreakdown()` if one exists. Used by the inline Today/30d
    /// KPI tiles (tasks.md 3.4 follow-up) so the UI layer doesn't need to re-derive day-key
    /// formatting itself.
    public func todayCreditsUsed(now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.calendar = calendar
        dayKeyFormatter.timeZone = calendar.timeZone
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayKeyFormatter.string(from: now)
        return self.dailyBreakdown(calendar: calendar, now: now).first { $0.day == todayKey }?.totalCreditsUsed
    }
}
