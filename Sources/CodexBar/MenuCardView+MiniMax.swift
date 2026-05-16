import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func minimaxMetrics(services: [MiniMaxServiceUsage], input: Input) -> [Metric] {
        let percentStyle: PercentStyle = .used
        let textGenerationCount = services.filter { $0.displayName == "Text Generation" }.count

        return services.enumerated().map { index, service in
            let used = service.usage
            let displayPercent = min(100, max(0, service.percent))
            let usageLabel = "Usage: \(used.formatted()) / \(service.limit.formatted())"
            let usedLabel = "Used \(String(format: "%.0f%%", displayPercent))"
            let title = if service.displayName == "Text Generation", textGenerationCount > 1 {
                "Text Generation · \(service.windowType == "Weekly" ? "Weekly" : "5h")"
            } else {
                service.displayName
            }

            return Metric(
                id: "minimax-service-\(index)",
                title: title,
                percent: displayPercent,
                percentStyle: percentStyle,
                resetText: service.resetDescription,
                detailText: service.timeRange,
                detailLeftText: usageLabel,
                detailRightText: usedLabel,
                pacePercent: nil,
                paceOnTop: true,
                cardStyle: true)
        }
    }
}
