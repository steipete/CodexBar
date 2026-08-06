import Foundation

public struct PoeUsageSnapshot: Sendable {
    public let currentPointBalance: Double?
    public let history: PoeUsageHistorySnapshot?
    public let updatedAt: Date

    public init(
        currentPointBalance: Double? = nil,
        history: PoeUsageHistorySnapshot? = nil,
        updatedAt: Date = Date())
    {
        self.currentPointBalance = currentPointBalance
        self.history = history
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .poe,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.balanceLabel)

        var rows: [ProviderDetailSection.Row] = []
        if let balance = self.currentPointBalance {
            rows.append(.makeRow(label: "Current balance", value: "\(Self.compactNumber(balance)) points"))
        }
        if let history = self.history {
            let today = history.currentDay(now: self.updatedAt, calendar: Self.utcCalendar)
            let seven = history.last7Days
            let thirty = history.last30Days
            rows.append(Self.summaryRow(label: "Today", summary: today))
            rows.append(Self.summaryRow(label: "Last 7 days", summary: seven))
            rows.append(Self.summaryRow(label: "Last 30 days", summary: thirty))
            if let top = history.topModels.first {
                rows.append(.makeRow(
                    label: "Top model",
                    value: top.name,
                    secondaryValue: "\(Self.compactNumber(top.points)) points"))
            }
            let usageMix = history.topUsageTypes.prefix(2)
                .map { "\($0.name): \(Self.compactNumber($0.points)) points" }
                .joined(separator: " · ")
            if !usageMix.isEmpty {
                rows.append(.makeRow(
                    label: "Usage mix",
                    value: usageMix))
            }
            for (index, entry) in history.recentEntries(limit: 3).enumerated() {
                rows.append(.makeRow(
                    label: index == 0 ? "Recent activity" : Self.timeString(entry.createdAt),
                    value: index == 0
                        ? "\(Self.timeString(entry.createdAt)) · \(entry.model)"
                        : entry.model,
                    secondaryValue: "\(Self.compactNumber(entry.points)) points"))
            }
        }
        let chart = self.history.flatMap { history in
            history.daily.isEmpty ? nil : ProviderDetailSection.makeChart(
                title: "Daily points",
                unit: "points",
                points: history.daily.map { ($0.day, $0.points) })
        }

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: [.makeSection(title: "Points", rows: rows, chart: chart)],
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private var balanceLabel: String? {
        guard let balance = self.currentPointBalance, balance.isFinite else { return nil }
        return "Balance: \(Self.compactNumber(balance)) points"
    }

    private static func summaryRow(
        label: String,
        summary: PoeUsageHistorySnapshot.Summary) -> ProviderDetailSection.Row
    {
        let secondary = [
            "\(summary.requests) requests",
            summary.costUSD.map(UsageFormatter.usdString),
        ].compactMap(\.self).joined(separator: " · ")
        return .makeRow(
            label: label,
            value: "\(Self.compactNumber(summary.points)) points",
            secondaryValue: secondary)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Poe reports in UTC; daily buckets already use it, and local zones would flake the goldens.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func compactNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
