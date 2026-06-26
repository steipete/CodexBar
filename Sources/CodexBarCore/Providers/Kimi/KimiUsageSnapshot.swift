import Foundation

public struct KimiUsageSnapshot: Sendable {
    public let weekly: KimiUsageDetail
    public let rateLimit: KimiUsageDetail?
    let rateLimits: [KimiRateLimit]
    public let updatedAt: Date
    let modelDisplayName: String?
    let membershipLevel: String?

    public init(
        weekly: KimiUsageDetail,
        rateLimit: KimiUsageDetail?,
        updatedAt: Date,
        modelDisplayName: String? = nil,
        membershipLevel: String? = nil)
    {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.rateLimits = []
        self.updatedAt = updatedAt
        self.modelDisplayName = modelDisplayName
        self.membershipLevel = membershipLevel
    }

    init(
        weekly: KimiUsageDetail,
        rateLimits: [KimiRateLimit],
        updatedAt: Date,
        modelDisplayName: String? = nil,
        membershipLevel: String? = nil)
    {
        self.weekly = weekly
        self.rateLimit = rateLimits.first?.detail
        self.rateLimits = rateLimits
        self.updatedAt = updatedAt
        self.modelDisplayName = modelDisplayName
        self.membershipLevel = membershipLevel
    }

    func withModelDisplayName(_ modelDisplayName: String?) -> KimiUsageSnapshot {
        KimiUsageSnapshot(
            weekly: self.weekly,
            rateLimits: self.rateLimits,
            updatedAt: self.updatedAt,
            modelDisplayName: modelDisplayName,
            membershipLevel: self.membershipLevel)
    }

    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }

    private static func usageWindow(from detail: KimiUsageDetail, window: KimiWindow? = nil) -> RateWindow {
        let limit = Int(detail.limit) ?? 0
        let remaining = Int(detail.remaining ?? "")
        let used = Int(detail.used ?? "") ?? {
            guard let remaining else { return 0 }
            return max(0, limit - remaining)
        }()
        let percent = limit > 0 ? Double(used) / Double(limit) * 100 : 0
        let windowMinutes = window.flatMap(Self.windowMinutes)
        let resetDescription = if let window, let duration = Self.durationDescription(window) {
            "\(used)/\(limit) requests per \(duration)"
        } else {
            "\(used)/\(limit) requests"
        }
        return RateWindow(
            usedPercent: percent,
            windowMinutes: windowMinutes,
            resetsAt: Self.parseDate(detail.resetTime),
            resetDescription: resetDescription)
    }

    private static func windowMinutes(_ window: KimiWindow) -> Int? {
        let duration = max(0, window.duration)
        switch window.timeUnit.uppercased() {
        case "TIME_UNIT_SECOND", "SECOND", "SECONDS":
            return max(1, Int(ceil(Double(duration) / 60.0)))
        case "TIME_UNIT_MINUTE", "MINUTE", "MINUTES":
            return duration
        case "TIME_UNIT_HOUR", "HOUR", "HOURS":
            return duration * 60
        case "TIME_UNIT_DAY", "DAY", "DAYS":
            return duration * 24 * 60
        case "TIME_UNIT_WEEK", "WEEK", "WEEKS":
            return duration * 7 * 24 * 60
        default:
            return nil
        }
    }

    private static func durationDescription(_ window: KimiWindow) -> String? {
        guard let minutes = windowMinutes(window), minutes > 0 else { return nil }
        if minutes % (7 * 24 * 60) == 0 {
            return Self.pluralDescription(minutes / (7 * 24 * 60), singular: "week", plural: "weeks")
        }
        if minutes % (24 * 60) == 0 {
            return Self.pluralDescription(minutes / (24 * 60), singular: "day", plural: "days")
        }
        if minutes % 60 == 0 {
            return Self.pluralDescription(minutes / 60, singular: "hour", plural: "hours")
        }
        return Self.pluralDescription(minutes, singular: "minute", plural: "minutes")
    }

    private static func pluralDescription(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    private static func extraRateWindowTitle(for rateLimit: KimiRateLimit, index: Int) -> String {
        guard let duration = durationDescription(rateLimit.window) else {
            return "Session \(index + 1)"
        }
        return "Session (\(duration))"
    }
}

extension KimiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let weeklyWindow = Self.usageWindow(from: self.weekly)
        let sessionWindow = if let firstRateLimit = self.rateLimits.first {
            Self.usageWindow(from: firstRateLimit.detail, window: firstRateLimit.window)
        } else {
            self.rateLimit.map { Self.usageWindow(from: $0) }
        }
        let extraWindows = self.rateLimits.dropFirst().enumerated().map { offset, rateLimit in
            NamedRateWindow(
                id: "kimi-session-\(offset + 2)",
                title: Self.extraRateWindowTitle(for: rateLimit, index: offset + 2),
                window: Self.usageWindow(from: rateLimit.detail, window: rateLimit.window))
        }

        let tier = KimiMembershipLevel.displayName(self.membershipLevel)
        let fastMode = KimiCodePricing.isHighSpeed(self.modelDisplayName)
        let loginMethod: String? = if let tier, fastMode {
            "\(tier) / Fast"
        } else if let tier {
            tier
        } else if fastMode {
            "Fast"
        } else {
            nil
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .kimi,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: sessionWindow ?? weeklyWindow,
            secondary: sessionWindow == nil ? nil : weeklyWindow,
            tertiary: nil,
            extraRateWindows: extraWindows.isEmpty ? nil : Array(extraWindows),
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
