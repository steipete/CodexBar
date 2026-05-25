import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func minimaxMetrics(services: [MiniMaxServiceUsage], input: Input) -> [Metric] {
        let percentStyle: PercentStyle = .used
        let textGenerationCount = services.count { $0.displayName == "Text Generation" }

        return services.enumerated().map { index, service in
            let used = service.usage
            let displayPercent = min(100, max(0, service.percent))
            let usageLabel = String(
                format: L("minimax_usage_amount_format"),
                used.formatted(),
                service.limit.formatted())
            let usedLabel = String(
                format: L("minimax_used_percent_format"),
                String(format: "%.0f%%", displayPercent))
            let localizedName = Self.localizedMiniMaxServiceName(service.displayName)
            let title = if localizedName == L("minimax_service_text_generation"), textGenerationCount > 1 {
                "\(L("minimax_service_text_generation")) · \(Self.displayWindowBadge(for: service.windowType))"
            } else {
                localizedName
            }

            return Metric(
                id: "minimax-service-\(index)",
                title: title,
                percent: displayPercent,
                percentStyle: percentStyle,
                resetText: Self.localizedMiniMaxResetDescription(service.resetDescription),
                detailText: service.timeRange,
                detailLeftText: usageLabel,
                detailRightText: usedLabel,
                pacePercent: nil,
                paceOnTop: true,
                cardStyle: true)
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
