import Foundation
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func syncCompanion() {
        let providers = self.store.enabledProvidersForDisplay()
        let models = providers.compactMap { self.menuCardModel(for: $0) }
        let companionModels = models.map { self.mapToCompanionModel($0) }

        // Sync to the iOS companion via iCloud Key-Value Store.
        if let encoded = try? JSONEncoder().encode(companionModels) {
            NSUbiquitousKeyValueStore.default.set(encoded, forKey: "latestUsageSync")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private func mapToCompanionModel(_ model: UsageMenuCardView.Model) -> CompanionCardModel {
        return CompanionCardModel(
            providerName: model.providerName,
            email: model.email,
            subtitleText: model.subtitleText,
            subtitleIsError: model.subtitleStyle == .error,
            planText: model.planText,
            metrics: model.metrics.map { m in
                CompanionCardModel.Metric(
                    id: m.id,
                    title: m.title,
                    percent: m.percent,
                    percentLabel: m.percentLabel,
                    accessibilityLabel: m.percentStyle.accessibilityLabel,
                    statusText: m.statusText,
                    resetText: m.resetText,
                    detailText: m.detailText,
                    detailLeftText: m.detailLeftText,
                    detailRightText: m.detailRightText,
                    pacePercent: m.pacePercent,
                    paceOnTop: m.paceOnTop,
                    warningMarkerPercents: m.warningMarkerPercents,
                    cardStyle: m.cardStyle
                )
            },
            usageNotes: model.usageNotes,
            creditsText: model.creditsText,
            creditsRemaining: model.creditsRemaining,
            creditsHintText: model.creditsHintText,
            creditsHintCopyText: model.creditsHintCopyText,
            providerCost: model.providerCost.map { c in
                CompanionCardModel.ProviderCostSection(
                    title: c.title,
                    percentUsed: c.percentUsed,
                    spendLine: c.spendLine,
                    percentLine: c.percentLine
                )
            },
            tokenUsage: model.tokenUsage.map { t in
                CompanionCardModel.TokenUsageSection(
                    sessionLine: t.sessionLine,
                    monthLine: t.monthLine,
                    hintLine: t.hintLine,
                    errorLine: t.errorLine,
                    errorCopyText: t.errorCopyText
                )
            },
            placeholder: model.placeholder,
            progressColorHex: model.progressColor.hexString ?? "#007AFF",
            updatedAt: Date()
        )
    }
}

extension Color {
    var hexString: String? {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
