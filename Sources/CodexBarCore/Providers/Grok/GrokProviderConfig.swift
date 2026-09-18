import Foundation

extension ProviderConfig {
    public var grokActiveSource: GrokActiveSource? {
        get { self.extensionValue(forKey: "grokActiveSource") }
        set { self.setExtensionValue(newValue, forKey: "grokActiveSource") }
    }
}
