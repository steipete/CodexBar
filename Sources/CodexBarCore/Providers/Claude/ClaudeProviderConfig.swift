import Foundation

extension ProviderConfig {
    public var claudeSwapEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeSwapEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapEnabled") }
    }

    public var claudeSwapShowSingleAccount: Bool? {
        get { self.extensionValue(forKey: "claudeSwapShowSingleAccount") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapShowSingleAccount") }
    }

    public var claudeSwapExecutablePath: String? {
        get { self.extensionValue(forKey: "claudeSwapExecutablePath") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapExecutablePath") }
    }

    public var sanitizedClaudeSwapExecutablePath: String? {
        Self.clean(self.claudeSwapExecutablePath)
    }
}
