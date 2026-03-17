import CodexBarCore
import Foundation

enum AppStrings {
    private static let table = "Localizable"
    #if DEBUG
    private nonisolated(unsafe) static var testingLanguageOverride: AppLanguage?
    #endif

    static func tr(_ key: String) -> String {
        AppStringResources.localizedString(for: key, table: self.table, language: self.currentLanguage)
    }

    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        self.fmt(key, arguments: args)
    }

    static func fmt(_ key: String, arguments: [CVarArg]) -> String {
        String(format: self.tr(key), locale: self.locale, arguments: arguments)
    }

    static var locale: Locale {
        self.currentLanguage.locale
    }

    #if DEBUG
    static func withTestingLanguage<T>(_ language: AppLanguage?, operation: () throws -> T) rethrows -> T {
        let previous = self.testingLanguageOverride
        self.testingLanguageOverride = language
        defer { self.testingLanguageOverride = previous }
        return try operation()
    }
    #endif

    private static var currentLanguage: AppLanguage {
        #if DEBUG
        if let testingLanguageOverride {
            return testingLanguageOverride
        }
        #endif
        return AppLanguage.resolve(from: .standard)
    }

    static func refreshFrequency(_ frequency: RefreshFrequency) -> String {
        switch frequency {
        case .manual:
            self.tr("Manual")
        case .oneMinute:
            self.tr("1 min")
        case .twoMinutes:
            self.tr("2 min")
        case .fiveMinutes:
            self.tr("5 min")
        case .fifteenMinutes:
            self.tr("15 min")
        case .thirtyMinutes:
            self.tr("30 min")
        }
    }

    static func menuBarMetricPreference(_ preference: MenuBarMetricPreference) -> String {
        switch preference {
        case .automatic:
            self.tr("Automatic")
        case .primary:
            self.tr("Primary")
        case .secondary:
            self.tr("Secondary")
        case .average:
            self.tr("Average")
        }
    }

    static func menuBarDisplayMode(_ mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .percent:
            self.tr("Percent")
        case .pace:
            self.tr("Pace")
        case .both:
            self.tr("Both")
        }
    }

    static func menuBarDisplayModeDescription(_ mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .percent:
            self.tr("Show remaining/used percentage (e.g. 45%)")
        case .pace:
            self.tr("Show pace indicator (e.g. +5%)")
        case .both:
            self.tr("Show both percentage and pace (e.g. 45% · +5%)")
        }
    }

    static func loadingPattern(_ pattern: LoadingPattern) -> String {
        switch pattern {
        case .knightRider:
            self.tr("Knight Rider")
        case .cylon:
            self.tr("Cylon")
        case .outsideIn:
            self.tr("Outside-In")
        case .race:
            self.tr("Race")
        case .pulse:
            self.tr("Pulse")
        case .unbraid:
            self.tr("Unbraid (logo → bars)")
        }
    }

    static func updateChannel(_ channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            self.tr("Stable")
        case .beta:
            self.tr("Beta")
        }
    }

    static func updateChannelDescription(_ channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            self.tr("Receive only stable, production-ready releases.")
        case .beta:
            self.tr("Receive stable releases plus beta previews.")
        }
    }

    static func providerStatus(_ indicator: ProviderStatusIndicator) -> String {
        switch indicator {
        case .none:
            self.tr("Operational")
        case .minor:
            self.tr("Partial outage")
        case .major:
            self.tr("Major outage")
        case .critical:
            self.tr("Critical issue")
        case .maintenance:
            self.tr("Maintenance")
        case .unknown:
            self.tr("Status unknown")
        }
    }

    static func localizedProviderStatusDescription(
        _ description: String?,
        indicator: ProviderStatusIndicator) -> String
    {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return self.providerStatus(indicator) }

        switch trimmed.lowercased() {
        case "operational", "all systems operational":
            return self.tr("Operational")
        case "partially degraded", "partially degraded service", "partial outage", "partial system outage",
             "degraded performance":
            return self.tr("Partial outage")
        case "major outage", "major service outage", "service outage":
            return self.tr("Major outage")
        case "critical outage", "critical service outage":
            return self.tr("Critical issue")
        case "maintenance", "under maintenance", "service under maintenance":
            return self.tr("Maintenance")
        default:
            return trimmed
        }
    }

    static func localizedSourceLabel(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        switch trimmed.lowercased() {
        case "auto":
            return self.tr("Auto")
        case "oauth":
            return self.tr("OAuth API")
        case "cli":
            return self.tr("CLI")
        case "web":
            return self.tr("web")
        case "api":
            return self.tr("API")
        case "openai-web":
            return self.tr("OpenAI web extras")
        default:
            return trimmed
        }
    }

    static func localizedOpenAIDashboardError(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let notFoundPrefix = "OpenAI dashboard data not found. Body sample: "
        if trimmed.hasPrefix(notFoundPrefix) {
            let sample = String(trimmed.dropFirst(notFoundPrefix.count)).trimmingCharacters(in: .whitespaces)
            return self.fmt("OpenAI dashboard data not found. Body sample: %@", sample)
        }

        let refreshPrefix = "Last OpenAI dashboard refresh failed: "
        let refreshSuffix = ". Cached values from "
        if trimmed.hasPrefix(refreshPrefix),
           let suffixRange = trimmed.range(of: refreshSuffix, options: .backwards)
        {
            let messageStart = trimmed.index(trimmed.startIndex, offsetBy: refreshPrefix.count)
            let message = trimmed[messageStart..<suffixRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = trimmed[suffixRange.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
            return self.fmt(
                "Last OpenAI dashboard refresh failed: %@. Cached values from %@.",
                String(message),
                String(stamp))
        }

        return trimmed
    }

    static func cookieSource(_ source: ProviderCookieSource) -> String {
        switch source {
        case .auto:
            self.tr("Auto")
        case .manual:
            self.tr("Manual")
        case .off:
            self.tr("Off")
        }
    }

    static func codexUsageSource(_ source: CodexUsageDataSource) -> String {
        switch source {
        case .auto:
            self.tr("Auto")
        case .oauth:
            self.tr("OAuth API")
        case .cli:
            self.tr("CLI (RPC/PTY)")
        }
    }

    static func claudeUsageSource(_ source: ClaudeUsageDataSource) -> String {
        switch source {
        case .auto:
            self.tr("Auto")
        case .oauth:
            self.tr("OAuth API")
        case .web:
            self.tr("Web API (cookies)")
        case .cli:
            self.tr("CLI (PTY)")
        }
    }

    static func kiloUsageSource(_ source: KiloUsageDataSource) -> String {
        switch source {
        case .auto:
            self.tr("Auto")
        case .api:
            self.tr("API")
        case .cli:
            self.tr("CLI")
        }
    }

    static func miniMaxRegion(_ region: MiniMaxAPIRegion) -> String {
        switch region {
        case .global:
            self.tr("Global (platform.minimax.io)")
        case .chinaMainland:
            self.tr("China mainland (platform.minimaxi.com)")
        }
    }

    static func zaiRegion(_ region: ZaiAPIRegion) -> String {
        switch region {
        case .global:
            self.tr("Global (api.z.ai)")
        case .bigmodelCN:
            self.tr("BigModel CN (open.bigmodel.cn)")
        }
    }

    static func usageLine(remaining: Double, used: Double, showUsed: Bool) -> String {
        let percent = showUsed ? used : remaining
        let clamped = min(100, max(0, percent))
        let suffix = showUsed ? self.tr("used") : self.tr("left")
        return String(format: "%.0f%% %@", locale: self.locale, clamped, suffix)
    }

    static func resetLine(for window: RateWindow, style: ResetTimeDisplayStyle, now: Date = .init()) -> String? {
        if let date = window.resetsAt {
            let text = style == .countdown
                ? self.resetCountdownDescription(from: date, now: now)
                : self.resetDescription(from: date, now: now)
            return self.fmt("Resets %@", text)
        }

        if let desc = window.resetDescription {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let localizedResets = self.tr("Resets")
            if trimmed.lowercased().hasPrefix(localizedResets.lowercased()) {
                return trimmed
            }
            if trimmed.lowercased().hasPrefix("resets") {
                let suffix = trimmed.dropFirst("Resets".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return self.fmt("Resets %@", suffix)
            }
            return self.fmt("Resets %@", trimmed)
        }
        return nil
    }

    static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return self.tr("now") }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return self.fmt("in %dd %dh", days, hours) }
            return self.fmt("in %dd", days)
        }
        if hours > 0 {
            if minutes > 0 { return self.fmt("in %dh %dm", hours, minutes) }
            return self.fmt("in %dh", hours)
        }
        return self.fmt("in %dm", totalMinutes)
    }

    static func resetDescription(from date: Date, now: Date = .init()) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.locale = self.locale
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.dateStyle = .medium
        dateTimeFormatter.timeStyle = .short
        dateTimeFormatter.locale = self.locale
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return self.fmt("tomorrow, %@", timeFormatter.string(from: date))
        }
        return dateTimeFormatter.string(from: date)
    }

    static func updatedString(from date: Date, now: Date = .init()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 60 {
            return self.tr("Updated just now")
        }
        if let hours = Calendar.current.dateComponents([.hour], from: date, to: now).hour, hours < 24 {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .abbreviated
            rel.locale = self.locale
            return self.fmt("Updated %@", rel.localizedString(for: date, relativeTo: now))
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.locale = self.locale
        return self.fmt("Updated %@", formatter.string(from: date))
    }

    static func creditsString(from value: Double) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.locale = self.locale
        let formatted = number.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", locale: self.locale, arguments: [value])
        return self.fmt("%@ left", formatted)
    }

    static func creditEventSummary(_ event: CreditEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = self.locale
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.locale = self.locale
        let credits = number.string(from: NSNumber(value: event.creditsUsed)) ?? "0"
        return self.fmt("%@ · %@ · %@ credits", formatter.string(from: event.date), event.service, credits)
    }

    static func creditEventCompact(_ event: CreditEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = self.locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.locale = self.locale
        let credits = number.string(from: NSNumber(value: event.creditsUsed)) ?? "0"
        return self.fmt("%@ — %@: %@", formatter.string(from: event.date), event.service, credits)
    }

    static func monthDayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = self.locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}
