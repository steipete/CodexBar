import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func monthlyTargetMetrics(_ metrics: [Metric], input: Input, calendar: Calendar) -> [Metric] {
        guard let snapshot = input.snapshot else { return metrics }
        let capability = ProviderDescriptorRegistry.descriptor(for: input.provider).pace
        return metrics.map { metric in
            guard metric.statusText == nil else { return metric }
            // The spend-only card projects this same budget into a metric instead of a cost section.
            if metric.id == "claude-extra-usage" {
                var result = metric
                result.dailyTargetText = Self.monthlyCostTarget(
                    cost: snapshot.providerCost,
                    input: input,
                    calendar: calendar)
                return result
            }
            let extra = snapshot.extraRateWindows?.first { $0.id == metric.id && $0.usageKnown }?.window
            let window: RateWindow? = switch metric.id {
            case "primary": snapshot.primary
            case "secondary": snapshot.secondary
            case "tertiary": snapshot.tertiary
            case "monthly": input.codexProjection?.rateWindow(for: .monthly) ?? extra
            default: extra
            }
            guard let window, !window.isSyntheticPlaceholder,
                  window.usedPercent.isFinite, window.usedPercent >= 0,
                  capability.usesInferredMonthlyDuration(window: window) ||
                  (window.windowMinutes.map { (28.0...31.0).contains((Double($0) / 1440).rounded()) } ?? false)
            else { return metric }
            let limit = window.quotaLimit ?? 100
            guard limit.isFinite, limit > 0 else { return metric }
            var result = metric
            let target = UsagePace.dailyTarget(
                remaining: limit * (window.remainingPercent / 100),
                resetsAt: window.resetsAt,
                now: input.now,
                calendar: calendar)
            result.dailyTargetText = UsagePaceText.dailyTarget(
                target,
                unit: window.quotaLimit == nil ? "%" : window.quotaUnit,
                preferredCurrency: input.preferredCurrencyCode)
            return result
        }
    }

    static func monthlyCostTarget(cost: ProviderCostSnapshot?, input: Input, calendar: Calendar) -> String? {
        guard let cost,
              ["monthly", "month", "this month", "monthly cap", "monthly credit limit"]
                  .contains(cost.period?.lowercased() ?? ""),
                  cost.limit.isFinite, cost.limit > 0, cost.used.isFinite, cost.used >= 0
        else { return nil }
        let target = UsagePace.dailyTarget(
            remaining: max(0, cost.limit - cost.used),
            resetsAt: cost.resetsAt,
            now: input.now,
            calendar: calendar)
        return UsagePaceText.dailyTarget(
            target,
            unit: cost.currencyCode,
            preferredCurrency: input.preferredCurrencyCode)
    }
}
