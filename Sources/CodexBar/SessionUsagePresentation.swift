import CodexBarCore
import Foundation

enum SessionUsagePresentation {
    enum Sort: CaseIterable, Hashable {
        case activity, tokens, cost

        var title: String {
            switch self {
            case .activity: L("Recent activity")
            case .tokens: L("Tokens")
            case .cost: L("Cost")
            }
        }
    }

    static func sessions(
        _ sessions: [CostUsageSessionBreakdown],
        matching query: String,
        hidePersonalInfo: Bool,
        sort: Sort = .activity,
        ascending: Bool = false) -> [CostUsageSessionBreakdown]
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            guard !query.isEmpty else { return true }
            let identity = CostHistoryIdentity(
                sessionID: session.sessionID,
                title: session.title,
                hidePersonalInfo: hidePersonalInfo)
            // Hidden titles must not be discoverable indirectly through search results.
            return identity.name.localizedStandardContains(query)
                || session.sessionID.localizedStandardContains(query)
        }.sorted { lhs, rhs in
            switch sort {
            case .activity:
                if lhs.lastActivity != rhs.lastActivity {
                    return ascending ? lhs.lastActivity < rhs.lastActivity : lhs.lastActivity > rhs.lastActivity
                }
            case .tokens:
                let left = lhs.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
                let right = rhs.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return ascending ? left < right : left > right
                }
            case .cost:
                let left = Self.convertedCost(lhs.costUSD, multiplier: 1)
                let right = Self.convertedCost(rhs.costUSD, multiplier: 1)
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return ascending ? left < right : left > right
                }
            }
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            return lhs.sessionID < rhs.sessionID
        }
    }

    static func uncachedInput(_ session: CostUsageSessionBreakdown) -> Int? {
        guard let input = session.inputTokens, let cached = session.cachedInputTokens,
              input >= 0, cached >= 0, cached <= input
        else { return nil }
        return input - cached
    }

    static func toolActivityRange(snapshot: CostUsageTokenSnapshot, calendar: Calendar) -> Range<Date> {
        let period = snapshot.reportingPeriod ?? .rolling(days: snapshot.historyDays)
        let bounds = period.bounds(now: snapshot.updatedAt, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: bounds.upperBound) ?? bounds.upperBound
        return bounds.lowerBound..<end
    }

    static func convertedCost(_ cost: Double?, multiplier: Double) -> Double? {
        guard let cost, cost.isFinite, cost >= 0, multiplier.isFinite, multiplier > 0 else { return nil }
        let result = cost * multiplier
        return result.isFinite ? result : nil
    }

    static func costText(_ cost: Double?, multiplier: Double, currencyCode: String) -> String {
        guard let value = convertedCost(cost, multiplier: multiplier) else { return "—" }
        guard value > 0, value < 1 else { return UsageFormatter.currencyString(value, currencyCode: currencyCode) }
        let minimum = 0.000001
        let text = max(minimum, value).formatted(
            .currency(code: currencyCode).precision(.fractionLength(2...6)).locale(Locale(identifier: "en_US")))
        return value < minimum ? "<" + text : text
    }
}
