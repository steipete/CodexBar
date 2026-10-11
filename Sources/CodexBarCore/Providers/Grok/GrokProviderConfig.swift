import Foundation

extension ProviderConfig {
    public var grokBotUsageEnabled: Bool? {
        get { self.extensionValue(forKey: "grokBotUsageEnabled") }
        set { self.setExtensionValue(newValue, forKey: "grokBotUsageEnabled") }
    }
}
