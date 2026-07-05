import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func minimaxMetrics(services: [MiniMaxServiceUsage], input: Input) -> [Metric] {
        let percentStyle: PercentStyle = .used
        let displayNameCounts = Dictionary(grouping: services.map(\.displayName), by: { $0 }).mapValues(\.count)

        return services.enumerated().map { index, service in
            let used = service.usage
            let displayPercent = min(100, max(0, service.percent))
            let usageLabel = if service.isUnlimited {
                nil as String?
            } else {
                String(
                    format: L("minimax_usage_amount_format"),
                    used.formatted(),
                    service.limit.formatted())
            }
            let localizedName = Self.localizedMiniMaxServiceName(service.displayName)
            let title = if (displayNameCounts[service.displayName] ?? 0) > 1 {
                "\(localizedName) · \(Self.displayWindowBadge(for: service.windowType))"
            } else {
                localizedName
            }

            return Metric(
                id: "minimax-service-\(index)",
                title: title,
                percent: displayPercent,
                percentStyle: percentStyle,
                statusText: service.isUnlimited ? "∞ Unlimited" : nil,
                resetText: Self.localizedMiniMaxResetDescription(service.resetDescription),
                detailText: nil,
                detailLeftText: usageLabel,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true,
                warningMarkerPercents: service.isUnlimited
                    ? []
                    : Self.miniMaxWarningMarkerPercents(service: service, input: input),
                workdayMarkerPercents: service.isUnlimited
                    ? []
                    : Self.miniMaxWorkdayMarkerPercents(service: service, input: input),
                cardStyle: false)
        }
    }

    private static func miniMaxWarningMarkerPercents(service: MiniMaxServiceUsage, input: Input) -> [Double] {
        switch self.miniMaxQuotaWarningWindow(for: service) {
        case .session:
            warningMarkerPercents(
                thresholds: input.quotaWarningThresholds[.session],
                showUsed: true)
        case .weekly:
            warningMarkerPercents(
                thresholds: input.quotaWarningThresholds[.weekly],
                showUsed: true)
        }
    }

    private static func miniMaxWorkdayMarkerPercents(service: MiniMaxServiceUsage, input: Input) -> [Double] {
        guard self.miniMaxQuotaWarningWindow(for: service) == .weekly else { return [] }
        return workDayMarkerPercents(
            workDays: input.workDaysPerWeek,
            windowMinutes: self.miniMaxWindowMinutes(for: service.windowType))
    }

    private static func miniMaxQuotaWarningWindow(for service: MiniMaxServiceUsage) -> QuotaWarningWindow {
        service.windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "weekly" ? .weekly : .session
    }

    private static func miniMaxWindowMinutes(for windowType: String) -> Int? {
        let normalized = windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "weekly" {
            return 7 * 24 * 60
        }
        if normalized == "today" || normalized == "daily" {
            return 24 * 60
        }
        if normalized == "5h" {
            return 5 * 60
        }
        let pieces = normalized.split(separator: " ")
        guard pieces.count >= 2, let value = Int(pieces[0]) else { return nil }
        switch pieces[1] {
        case "hour", "hours", "hr", "hrs":
            return value * 60
        case "minute", "minutes", "min", "mins":
            return value
        default:
            return nil
        }
    }

    private static func displayWindowBadge(for windowType: String) -> String {
        let trimmed = windowType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if normalized == "weekly" {
            return L("Weekly")
        }
        if normalized == "5 hours" || normalized == "5 hour" || normalized == "5h" {
            return "5h"
        }
        if normalized == "today" {
            return L("Today")
        }
        if normalized == "daily" {
            return L("Daily")
        }
        return trimmed.isEmpty ? windowType : trimmed
    }

    private static func localizedMiniMaxResetDescription(_ text: String) -> String {
        let prefix = "Resets in "
        guard text.hasPrefix(prefix) else { return text }
        let rest = String(text.dropFirst(prefix.count))
        return L("Resets in %@", rest)
    }

    private static func localizedMiniMaxServiceName(_ raw: String) -> String {
        switch raw {
        case "Text Generation", "text_generation":
            L("minimax_service_text_generation")
        case "Text to Speech", "text_to_speech":
            L("minimax_service_text_to_speech")
        case "Music Generation", "music_generation":
            L("minimax_service_music_generation")
        case "Image Generation", "image_generation":
            L("minimax_service_image_generation")
        case "lyrics_generation":
            L("minimax_service_lyrics_generation")
        case "coding-plan-vlm":
            L("minimax_service_coding_plan_vlm")
        case "coding-plan-search":
            L("minimax_service_coding_plan_search")
        default:
            raw
        }
    }
}
