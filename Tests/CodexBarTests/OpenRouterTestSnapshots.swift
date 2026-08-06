#if canImport(JavaScriptCore)
import Foundation
@testable import CodexBarCore

/// Test-only fixture projection for UI tests. Production JavaScriptCore builds use openrouter.js.
struct OpenRouterRateLimit: Sendable {
    let requests: Int
    let interval: String
}

struct OpenRouterUsageSnapshot: Sendable {
    let totalCredits: Double
    let totalUsage: Double
    let balance: Double
    let usedPercent: Double
    let keyDataFetched: Bool
    let keyLimit: Double?
    let keyLimitRemaining: Double?
    let keyLimitReset: String?
    let keyUsage: Double?
    let keyUsageDaily: Double?
    let keyUsageWeekly: Double?
    let keyUsageMonthly: Double?
    let rateLimit: OpenRouterRateLimit?
    let updatedAt: Date

    init(
        totalCredits: Double,
        totalUsage: Double,
        balance: Double,
        usedPercent: Double,
        keyDataFetched: Bool = false,
        keyLimit: Double? = nil,
        keyLimitRemaining: Double? = nil,
        keyLimitReset: String? = nil,
        keyUsage: Double? = nil,
        keyUsageDaily: Double? = nil,
        keyUsageWeekly: Double? = nil,
        keyUsageMonthly: Double? = nil,
        rateLimit: OpenRouterRateLimit?,
        updatedAt: Date)
    {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.balance = balance
        self.usedPercent = usedPercent
        self.keyDataFetched = keyDataFetched || keyLimit != nil || keyLimitRemaining != nil || keyUsage != nil ||
            keyUsageDaily != nil || keyUsageWeekly != nil || keyUsageMonthly != nil
        self.keyLimit = keyLimit
        self.keyLimitRemaining = keyLimitRemaining
        self.keyLimitReset = keyLimitReset
        self.keyUsage = keyUsage
        self.keyUsageDaily = keyUsageDaily
        self.keyUsageWeekly = keyUsageWeekly
        self.keyUsageMonthly = keyUsageMonthly
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
    }

    func toUsageSnapshot() -> UsageSnapshot {
        let keyUsed = self.keyUsed
        let primary: RateWindow? = if let keyLimit, keyLimit > 0, let keyUsed, keyUsed >= 0 {
            RateWindow(
                usedPercent: min(100, max(0, keyUsed / keyLimit * 100)),
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil)
        } else {
            nil
        }
        let currency = { (value: Double) in UsageFormatter.usdString(value) }
        var details: [ProviderDetailSection] = [.makeSection(title: "Credits", rows: [
            .makeRow(label: "Remaining", value: currency(self.balance)),
            .makeRow(label: "Used", value: currency(self.totalUsage)),
            .makeRow(label: "Total added", value: currency(self.totalCredits)),
        ])]
        if self.keyDataFetched {
            var rows: [ProviderDetailSection.Row] = []
            if let keyLimit, keyLimit > 0 {
                rows.append(.makeRow(label: "API key budget", value: currency(keyLimit)))
                if let keyUsed {
                    rows.append(.makeRow(
                        label: "API key remaining",
                        value: currency(max(0, keyLimit - keyUsed))))
                }
                if let keyUsage {
                    rows.append(.makeRow(label: "API key used", value: currency(keyUsage)))
                }
            } else {
                rows.append(.makeRow(label: "API key budget", value: "No limit configured"))
            }
            if let reset = self.keyLimitReset?.trimmingCharacters(in: .whitespacesAndNewlines), !reset.isEmpty {
                rows.append(.makeRow(label: "Reset window", value: reset))
            }
            let periods = [
                ("Today", self.keyUsageDaily),
                ("This week", self.keyUsageWeekly),
                ("This month", self.keyUsageMonthly),
            ]
            for (label, value) in periods {
                if let value {
                    rows.append(.makeRow(label: label, value: currency(value)))
                }
            }
            if let rateLimit {
                rows.append(.makeRow(
                    label: "Rate limit",
                    value: "\(rateLimit.requests) requests / \(rateLimit.interval)"))
            }
            let points = periods.compactMap { label, value in value.map { (label, $0) } }
            details.append(.makeSection(
                title: "API key",
                rows: rows,
                chart: points.isEmpty ? nil : .makeChart(title: "Key spend", unit: "USD", points: points)))
        } else {
            details.append(.makeSection(title: "API key", rows: [
                .makeRow(label: "API key budget", value: "Unavailable right now"),
            ]))
        }
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .openrouter,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: \(currency(self.balance))"))
    }

    private var keyUsed: Double? {
        guard self.keyDataFetched, let keyLimit, keyLimit > 0 else { return nil }
        if let keyLimitRemaining, keyLimitRemaining.isFinite {
            return keyLimit - min(keyLimit, max(0, keyLimitRemaining))
        }
        return switch self.keyLimitReset?.lowercased() {
        case "daily": self.keyUsageDaily ?? self.keyUsage
        case "weekly": self.keyUsageWeekly ?? self.keyUsage
        case "monthly": self.keyUsageMonthly ?? self.keyUsage
        default: self.keyUsage
        }
    }
}
#endif
