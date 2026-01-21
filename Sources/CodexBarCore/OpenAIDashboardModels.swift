import Foundation

public struct OpenAIDashboardSnapshot: Codable, Equatable, Sendable {
    public let signedInEmail: String?
    public let codeReviewRemainingPercent: Double?
    public let creditEvents: [CreditEvent]
    public let dailyBreakdown: [OpenAIDashboardDailyBreakdown]
    /// Usage breakdown time series from the Codex dashboard chart ("Usage breakdown", 30 days).
    ///
    /// This is distinct from `dailyBreakdown`, which is derived from `creditEvents` (credits usage history table).
    public let usageBreakdown: [OpenAIDashboardDailyBreakdown]
    public let creditsPurchaseURL: String?
    public let primaryLimit: RateWindow?
    public let secondaryLimit: RateWindow?
    public let creditsRemaining: Double?
    public let accountPlan: String?
    public let updatedAt: Date

    public init(
        signedInEmail: String?,
        codeReviewRemainingPercent: Double?,
        creditEvents: [CreditEvent],
        dailyBreakdown: [OpenAIDashboardDailyBreakdown],
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        creditsPurchaseURL: String?,
        primaryLimit: RateWindow? = nil,
        secondaryLimit: RateWindow? = nil,
        creditsRemaining: Double? = nil,
        accountPlan: String? = nil,
        updatedAt: Date)
    {
        self.signedInEmail = signedInEmail
        self.codeReviewRemainingPercent = codeReviewRemainingPercent
        self.creditEvents = creditEvents
        self.dailyBreakdown = dailyBreakdown
        self.usageBreakdown = usageBreakdown
        self.creditsPurchaseURL = creditsPurchaseURL
        self.primaryLimit = primaryLimit
        self.secondaryLimit = secondaryLimit
        self.creditsRemaining = creditsRemaining
        self.accountPlan = accountPlan
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case signedInEmail
        case codeReviewRemainingPercent
        case creditEvents
        case dailyBreakdown
        case usageBreakdown
        case creditsPurchaseURL
        case primaryLimit
        case secondaryLimit
        case creditsRemaining
        case accountPlan
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.signedInEmail = try container.decodeIfPresent(String.self, forKey: .signedInEmail)
        self.codeReviewRemainingPercent = try container.decodeIfPresent(
            Double.self,
            forKey: .codeReviewRemainingPercent)
        self.creditEvents = try container.decodeIfPresent([CreditEvent].self, forKey: .creditEvents) ?? []
        self.dailyBreakdown = try container.decodeIfPresent(
            [OpenAIDashboardDailyBreakdown].self,
            forKey: .dailyBreakdown)
            ?? Self.makeDailyBreakdown(from: self.creditEvents, maxDays: 30)
        self.usageBreakdown = try container.decodeIfPresent(
            [OpenAIDashboardDailyBreakdown].self,
            forKey: .usageBreakdown) ?? []
        self.creditsPurchaseURL = try container.decodeIfPresent(String.self, forKey: .creditsPurchaseURL)
        self.primaryLimit = try container.decodeIfPresent(RateWindow.self, forKey: .primaryLimit)
        self.secondaryLimit = try container.decodeIfPresent(RateWindow.self, forKey: .secondaryLimit)
        self.creditsRemaining = try container.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        self.accountPlan = try container.decodeIfPresent(String.self, forKey: .accountPlan)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public static func makeDailyBreakdown(from events: [CreditEvent], maxDays: Int) -> [OpenAIDashboardDailyBreakdown] {
        guard !events.isEmpty else { return [] }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"

        var totals: [String: [String: Double]] = [:] // day -> service -> credits
        for event in events {
            let day = formatter.string(from: event.date)
            totals[day, default: [:]][event.service, default: 0] += event.creditsUsed
        }

        let sortedDays = totals.keys.sorted(by: >).prefix(maxDays)
        return sortedDays.map { day in
            let serviceTotals = totals[day] ?? [:]
            let services = serviceTotals
                .map { OpenAIDashboardServiceUsage(service: $0.key, creditsUsed: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.creditsUsed == rhs.creditsUsed { return lhs.service < rhs.service }
                    return lhs.creditsUsed > rhs.creditsUsed
                }
            let total = services.reduce(0) { $0 + $1.creditsUsed }
            return OpenAIDashboardDailyBreakdown(day: day, services: services, totalCreditsUsed: total)
        }
    }
}

extension OpenAIDashboardSnapshot {
    public func toUsageSnapshot(
        provider: UsageProvider = .codex,
        accountEmail: String? = nil,
        accountPlan: String? = nil) -> UsageSnapshot?
    {
        guard let primaryLimit else { return nil }
        let resolvedEmail = accountEmail ?? self.signedInEmail
        let resolvedPlan = accountPlan ?? self.accountPlan
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: nil,
            loginMethod: resolvedPlan)
        return UsageSnapshot(
            primary: primaryLimit,
            secondary: self.secondaryLimit,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public func toCreditsSnapshot() -> CreditsSnapshot? {
        guard let creditsRemaining else { return nil }
        return CreditsSnapshot(remaining: creditsRemaining, events: self.creditEvents, updatedAt: self.updatedAt)
    }
}

public struct OpenAIDashboardDailyBreakdown: Codable, Equatable, Sendable {
    /// Day key in `yyyy-MM-dd` (local time).
    public let day: String
    public let services: [OpenAIDashboardServiceUsage]
    public let totalCreditsUsed: Double

    public init(day: String, services: [OpenAIDashboardServiceUsage], totalCreditsUsed: Double) {
        self.day = day
        self.services = services
        self.totalCreditsUsed = totalCreditsUsed
    }
}

public struct OpenAIDashboardServiceUsage: Codable, Equatable, Sendable {
    public let service: String
    public let creditsUsed: Double

    public init(service: String, creditsUsed: Double) {
        self.service = service
        self.creditsUsed = creditsUsed
    }
}

public struct OpenAIDashboardCache: Codable, Equatable, Sendable {
    public let accountEmail: String
    public let snapshot: OpenAIDashboardSnapshot

    public init(accountEmail: String, snapshot: OpenAIDashboardSnapshot) {
        self.accountEmail = accountEmail
        self.snapshot = snapshot
    }
}

public enum OpenAIDashboardCacheStore {
    public static func load() -> OpenAIDashboardCache? {
        guard let url = self.cacheURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OpenAIDashboardCache.self, from: data)
    }

    public static func save(_ cache: OpenAIDashboardCache) {
        guard let url = self.cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort cache only; ignore errors.
        }
    }

    public static func clear() {
        guard let url = self.cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var cacheURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("openai-dashboard.json")
    }
}
