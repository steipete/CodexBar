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

    enum CodingKeys: String, CodingKey {
        case provider
        case planName
        case status
        case subscriptionRenewsAt
        case subscriptionExpiresAt
        case source
        case confidence
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(UsageProvider.self, forKey: .provider)
        self.planName = try Self.normalized(container.decodeIfPresent(String.self, forKey: .planName))
        self.status = try container.decode(ProviderSubscriptionStatus.self, forKey: .status)
        self.subscriptionRenewsAt = try Self.decodeDateIfPresent(container, forKey: .subscriptionRenewsAt)
        self.subscriptionExpiresAt = try Self.decodeDateIfPresent(container, forKey: .subscriptionExpiresAt)
        self.source = try container.decodeIfPresent(ProviderSubscriptionSource.self, forKey: .source) ?? .manual
        self.confidence = try container
            .decodeIfPresent(ProviderSubscriptionConfidence.self, forKey: .confidence) ?? .manual
        self.updatedAt = try Self.decodeDate(container, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.provider, forKey: .provider)
        try container.encodeIfPresent(self.planName, forKey: .planName)
        try container.encode(self.status, forKey: .status)
        try Self.encodeDateIfPresent(self.subscriptionRenewsAt, to: &container, forKey: .subscriptionRenewsAt)
        try Self.encodeDateIfPresent(self.subscriptionExpiresAt, to: &container, forKey: .subscriptionExpiresAt)
        try container.encode(self.source, forKey: .source)
        try container.encode(self.confidence, forKey: .confidence)
        try Self.encodeDate(self.updatedAt, to: &container, forKey: .updatedAt)
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

    private static func decodeDateIfPresent(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) throws -> Date?
    {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return nil }
        return try self.decodeDate(container, forKey: key)
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) throws -> Date
    {
        if let rawString = try? container.decodeIfPresent(String.self, forKey: key),
           let parsed = parseDateString(rawString)
        {
            return parsed
        }
        if let unixSeconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: unixSeconds)
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected ISO-8601 date string or unix-seconds number")
    }

    private static func parseDateString(_ value: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func encodeDate(
        _ value: Date,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys) throws
    {
        try container.encode(self.iso8601String(from: value), forKey: key)
    }

    private static func encodeDateIfPresent(
        _ value: Date?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys) throws
    {
        guard let value else {
            try container.encodeNil(forKey: key)
            return
        }
        try self.encodeDate(value, to: &container, forKey: key)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum ProviderSubscriptionFormatter {
    public static func menuLine(
        from snapshot: ProviderSubscriptionSnapshot,
        now: Date = .init(),
        calendar: Calendar = .current,
        locale: Locale = .current) -> String?
    {
        if let expires = snapshot.subscriptionExpiresAt {
            return self.expiresLine(date: expires, now: now, calendar: calendar, locale: locale)
        }
        if let renews = snapshot.subscriptionRenewsAt,
           snapshot.status == .active || snapshot.status == .trialing
        {
            return self.renewsLine(date: renews, now: now, calendar: calendar, locale: locale)
        }
        return nil
    }

    private static func renewsLine(date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let dayDelta = dayDelta(from: now, to: date, calendar: calendar)
        if dayDelta == 0 { return "Renews today" }
        return "Renews \(self.formattedDate(date, locale: locale))"
    }

    private static func expiresLine(date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let dayDelta = dayDelta(from: now, to: date, calendar: calendar)
        if dayDelta < 0 {
            return "Expired \(self.formattedDate(date, locale: locale))"
        }
        if dayDelta == 0 { return "Expires today" }
        if dayDelta <= 7 {
            let label = dayDelta == 1 ? "day" : "days"
            return "Expires in \(dayDelta) \(label)"
        }
        return "Expires \(self.formattedDate(date, locale: locale))"
    }

    private static func formattedDate(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().locale(locale))
    }

    private static func dayDelta(from now: Date, to date: Date, calendar: Calendar) -> Int {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0
    }
}
