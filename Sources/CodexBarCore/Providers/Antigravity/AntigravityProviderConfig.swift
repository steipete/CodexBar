import Foundation

extension ProviderConfig {
    public var antigravityAdditionalProfileHomes: [String]? {
        get { self.extensionValue(forKey: "antigravityAdditionalProfileHomes") }
        set { self.setExtensionValue(newValue, forKey: "antigravityAdditionalProfileHomes") }
    }

    public var antigravityPrioritizeExhaustedQuotas: Bool? {
        get { self.extensionValue(forKey: "antigravityPrioritizeExhaustedQuotas") }
        set { self.setExtensionValue(newValue, forKey: "antigravityPrioritizeExhaustedQuotas") }
    }
}
