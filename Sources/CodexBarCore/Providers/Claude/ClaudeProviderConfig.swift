import Foundation

extension ProviderConfig {
    public var claudeDesktopCookiesEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeDesktopCookiesEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeDesktopCookiesEnabled") }
    }

    /// Persisted with the visibility choices so an upgrade or sync cannot reapply the legacy global gate.
    public var claudeResetCreditsVisibilityMigrated: Bool? {
        get { self.extensionValue(forKey: "claudeResetCreditsVisibilityMigrated") }
        set { self.setExtensionValue(newValue, forKey: "claudeResetCreditsVisibilityMigrated") }
    }

    public var claudeWorkspaceSpendEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeWorkspaceSpendEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeWorkspaceSpendEnabled") }
    }

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
        SettingsValue.cleaned(self.claudeSwapExecutablePath)
    }

    /// `"claude-swap"` (default) or `"tcr"`: which tool the executable path names.
    public var claudeSwapSource: String? {
        get { self.extensionValue(forKey: "claudeSwapSource") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapSource") }
    }

    /// An unset or unrecognised value reads as claude-swap, the source that predates the key.
    public var resolvedClaudeSwapSource: ClaudeSwapAccountSource {
        SettingsValue.cleaned(self.claudeSwapSource).flatMap(ClaudeSwapAccountSource.init(rawValue:)) ?? .claudeSwap
    }
}
