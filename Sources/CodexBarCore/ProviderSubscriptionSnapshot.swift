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
    private static let manualDateCalendar = Calendar(identifier: .gregorian)
    private static let manualDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Self.manualDateCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
        self.subscriptionRenewsAt = Self.normalizedManualDate(subscriptionRenewsAt)
        self.subscriptionExpiresAt = Self.normalizedManualDate(subscriptionExpiresAt)
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
        if let date = self.parseManualDateString(value) {
            return date
        }
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
        try container.encode(self.manualDateString(from: value), forKey: key)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func normalizedManualDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let components = self.manualDateCalendar.dateComponents(in: .current, from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return date
        }
        return self.manualDateCalendar.date(
            from: DateComponents(timeZone: .gmt, year: year, month: month, day: day, hour: 12))
    }

    private static func manualDateString(from date: Date) -> String {
        self.manualDateFormatter.string(from: date)
    }

    private static func parseManualDateString(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.isCalendarDayLiteral(trimmed) {
            return self.dateFromCalendarDayLiteral(trimmed)
        }

        if let literal = Self.extractMidnightUTCCalendarDay(trimmed) {
            return self.dateFromCalendarDayLiteral(literal)
        }

        return nil
    }

    private static func isCalendarDayLiteral(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let bytes = Array(value.utf8)
        return bytes[4] == 45 && bytes[7] == 45
            && bytes.enumerated().allSatisfy { index, byte in
                if index == 4 || index == 7 { return true }
                return byte >= 48 && byte <= 57
            }
    }

    private static func extractMidnightUTCCalendarDay(_ value: String) -> String? {
        let suffixes = [
            "T00:00:00Z",
            "T00:00:00.000Z",
            "T00:00:00.000000Z",
        ]
        guard let suffix = suffixes.first(where: { value.hasSuffix($0) }) else { return nil }
        let prefix = String(value.dropLast(suffix.count))
        return Self.isCalendarDayLiteral(prefix) ? prefix : nil
    }

    private static func dateFromCalendarDayLiteral(_ value: String) -> Date? {
        guard let startOfDayUTC = self.manualDateFormatter.date(from: value) else { return nil }
        return self.manualDateCalendar.date(byAdding: .hour, value: 12, to: startOfDayUTC)
    }

    static func manualDisplayCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

public enum ProviderSubscriptionFormatter {
    public struct Strings: Sendable {
        public let renewsToday: String
        public let renewsDateFormat: String
        public let expiredDateFormat: String
        public let expiresToday: String
        public let expiresInOneDay: String
        public let expiresInDaysFormat: String
        public let expiresDateFormat: String

        public init(
            renewsToday: String,
            renewsDateFormat: String,
            expiredDateFormat: String,
            expiresToday: String,
            expiresInOneDay: String,
            expiresInDaysFormat: String,
            expiresDateFormat: String)
        {
            self.renewsToday = renewsToday
            self.renewsDateFormat = renewsDateFormat
            self.expiredDateFormat = expiredDateFormat
            self.expiresToday = expiresToday
            self.expiresInOneDay = expiresInOneDay
            self.expiresInDaysFormat = expiresInDaysFormat
            self.expiresDateFormat = expiresDateFormat
        }

        public static let english = Strings(
            renewsToday: "Renews today",
            renewsDateFormat: "Renews %@",
            expiredDateFormat: "Expired %@",
            expiresToday: "Expires today",
            expiresInOneDay: "Expires in 1 day",
            expiresInDaysFormat: "Expires in %d days",
            expiresDateFormat: "Expires %@")
    }

    public static func menuLine(
        from snapshot: ProviderSubscriptionSnapshot,
        now: Date = .init(),
        calendar _: Calendar = .current,
        locale: Locale = .current,
        strings: Strings = .english) -> String?
    {
        if let expires = snapshot.subscriptionExpiresAt {
            return self.expiresLine(
                date: expires,
                now: now,
                locale: locale,
                strings: strings)
        }
        if let renews = snapshot.subscriptionRenewsAt,
           snapshot.status == .active || snapshot.status == .trialing
        {
            return self.renewsLine(
                date: renews,
                now: now,
                locale: locale,
                strings: strings)
        }
        return nil
    }

    private static func renewsLine(
        date: Date,
        now: Date,
        locale: Locale,
        strings: Strings) -> String
    {
        let dayDelta = dayDelta(from: now, to: date)
        if dayDelta == 0 { return strings.renewsToday }
        return String(
            format: strings.renewsDateFormat,
            locale: locale,
            self.formattedDate(date, locale: locale))
    }

    private static func expiresLine(
        date: Date,
        now: Date,
        locale: Locale,
        strings: Strings) -> String
    {
        let dayDelta = dayDelta(from: now, to: date)
        if dayDelta < 0 {
            return String(
                format: strings.expiredDateFormat,
                locale: locale,
                self.formattedDate(date, locale: locale))
        }
        if dayDelta == 0 { return strings.expiresToday }
        if dayDelta == 1 { return strings.expiresInOneDay }
        if dayDelta <= 7 { return String(format: strings.expiresInDaysFormat, locale: locale, dayDelta) }
        return String(
            format: strings.expiresDateFormat,
            locale: locale,
            self.formattedDate(date, locale: locale))
    }

    private static func formattedDate(_ date: Date, locale: Locale) -> String {
        let calendar = ProviderSubscriptionSnapshot.manualDisplayCalendar()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    private static func dayDelta(from now: Date, to date: Date) -> Int {
        let manualCalendar = ProviderSubscriptionSnapshot.manualDisplayCalendar()
        let startNow = manualCalendar.startOfDay(for: now)
        let startDate = manualCalendar.startOfDay(for: date)
        return manualCalendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0
    }
}
