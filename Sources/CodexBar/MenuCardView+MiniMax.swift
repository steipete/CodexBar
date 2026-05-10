import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func minimaxMetrics(services: [MiniMaxServiceUsage], input: Input) -> [Metric] {
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left

        return services.enumerated().map { index, service in
            let used = service.usage
            let remaining = service.remaining
            let displayValue = input.usageBarsShowUsed ? used : remaining
            let displayPercent = input.usageBarsShowUsed ? service.percent : (100 - service.percent)

            return Metric(
                id: "minimax-service-\(index)",
                title: service.displayName,
                percent: min(100, max(0, displayPercent)),
                percentStyle: percentStyle,
                resetText: service.resetDescription,
                detailText: "\(displayValue)/\(service.limit)",
                detailLeftText: service.windowType,
                detailRightText: String(format: "%.0f%%", displayPercent),
                pacePercent: nil,
                paceOnTop: true)
        }
    }
}
