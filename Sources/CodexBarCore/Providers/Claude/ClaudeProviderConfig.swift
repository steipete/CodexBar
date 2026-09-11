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

    public var claudeInstancesEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeInstancesEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeInstancesEnabled") }
    }

    public var claudeInstances: [ClaudeInstanceConfig]? {
        get { self.extensionValue(forKey: "claudeInstances") }
        set { self.setExtensionValue(newValue, forKey: "claudeInstances") }
    }

    /// Config directories of the configured instances when the feature is on; feeds local cost scanning.
    public var enabledClaudeInstanceConfigDirectories: [String] {
        guard self.claudeInstancesEnabled == true else { return [] }
        return (self.claudeInstances ?? []).compactMap(\.normalizedConfigDirectory)
    }
}
