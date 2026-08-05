import Foundation

extension ProviderConfig {
    public var antigravityPrioritizeExhaustedQuotas: Bool? {
        get { self.extensionValue(forKey: "antigravityPrioritizeExhaustedQuotas") }
        set { self.setExtensionValue(newValue, forKey: "antigravityPrioritizeExhaustedQuotas") }
    }
}
