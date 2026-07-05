import CodexBarCore
import Foundation

extension DeepSeekStatusSummary {
    var providerStatus: ProviderStatus {
        ProviderStatus(
            indicator: ProviderStatusIndicator(rawValue: self.indicator) ?? .unknown,
            description: self.description,
            updatedAt: self.updatedAt)
    }

    var providerComponents: [ProviderStatusComponent] {
        self.components.map { component in
            let normalized = DeepSeekStatusFetcher.normalizedStatuspageStatus(component.status)
            return ProviderStatusComponent(
                id: component.id,
                name: component.name,
                indicator: ProviderStatusComponent.indicator(forStatuspageStatus: normalized),
                status: normalized)
        }
    }
}
