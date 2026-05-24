import Foundation

public enum ProviderSubscriptionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case trialing
    case canceled
    case pastDue
    case unknown
}

public enum ProviderSubscriptionSource: String, Codable, Sendable, CaseIterable {
    case manual
}

public enum ProviderSubscriptionConfidence: String, Codable, Sendable, CaseIterable {
    case manual
}

public struct ProviderSubscriptionSnapshot: Codable, Sendable, Equatable {
    public let provider: UsageProvider
    public let planName: String?
    public let status: ProviderSubscriptionStatus
    public let subscriptionRenewsAt: Date?
    public let subscriptionExpiresAt: Date?
    public let source: ProviderSubscriptionSource
    public let confidence: ProviderSubscriptionConfidence
    public let updatedAt: Date

    public init(
        provider: UsageProvider,
        planName: String?,
        status: ProviderSubscriptionStatus,
        subscriptionRenewsAt: Date?,
        subscriptionExpiresAt: Date?,
        source: ProviderSubscriptionSource = .manual,
        confidence: ProviderSubscriptionConfidence = .manual,
        updatedAt: Date)
    {
        self.provider = provider
        self.planName = Self.normalized(planName)
        self.status = status
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.source = source
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public var hasDisplayableDate: Bool {
        self.subscriptionRenewsAt != nil || self.subscriptionExpiresAt != nil
    }

    public func withProvider(_ provider: UsageProvider) -> ProviderSubscriptionSnapshot {
        ProviderSubscriptionSnapshot(
            provider: provider,
            planName: self.planName,
            status: self.status,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            source: .manual,
            confidence: .manual,
            updatedAt: self.updatedAt)
    }

    private static func normalized(_ planName: String?) -> String? {
        guard let planName else { return nil }
        let trimmed = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ProviderSubscriptionFormatter {
    public static func menuLine(
        from snapshot: ProviderSubscriptionSnapshot,
        now: Date = .init(),
        calendar: Calendar = .current) -> String?
    {
        if let expires = snapshot.subscriptionExpiresAt {
            return self.expiresLine(date: expires, now: now, calendar: calendar)
        }
        if let renews = snapshot.subscriptionRenewsAt,
           snapshot.status == .active || snapshot.status == .trialing
        {
            return self.renewsLine(date: renews, now: now, calendar: calendar)
        }
        return nil
    }

    private static func renewsLine(date: Date, now: Date, calendar: Calendar) -> String {
        let dayDelta = self.dayDelta(from: now, to: date, calendar: calendar)
        if dayDelta == 0 { return "Renews today" }
        return "Renews \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func expiresLine(date: Date, now: Date, calendar: Calendar) -> String {
        let dayDelta = self.dayDelta(from: now, to: date, calendar: calendar)
        if dayDelta < 0 {
            return "Expired \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        if dayDelta == 0 { return "Expires today" }
        if dayDelta <= 7 {
            let label = dayDelta == 1 ? "day" : "days"
            return "Expires in \(dayDelta) \(label)"
        }
        return "Expires \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func dayDelta(from now: Date, to date: Date, calendar: Calendar) -> Int {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0
    }
}
