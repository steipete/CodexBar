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
        SettingsValue.cleaned(self.claudeSwapExecutablePath)
    }

    /// The executable claude-swap consumers should actually run: the configured path when set,
    /// otherwise the standard install location — but only when something executable is really
    /// there, so users without claude-swap installed see no change.
    ///
    /// Shared by the app, `codexbar cards` and the dashboard. Keeping it here rather than in the
    /// app's settings store is deliberate: an app-only fallback would leave the CLI passing an
    /// empty path to the reader, which rejects it, so the same configuration would work in the
    /// menu bar and fail on the command line.
    public var resolvedClaudeSwapExecutablePath: String {
        ClaudeSwapExecutableResolver.resolve(configured: self.sanitizedClaudeSwapExecutablePath)
    }
}

public enum ClaudeSwapExecutableResolver {
    /// The install location assumed when the user has not chosen one. Matches the path the
    /// settings field shows as its placeholder, which users reasonably read as a default.
    public static var defaultExecutablePath: String {
        NSString(string: "~/.local/bin/cswap").expandingTildeInPath
    }

    /// Display form of the default, for placeholders and messages.
    public static let defaultExecutablePathPlaceholder = "~/.local/bin/cswap"

    /// Pure resolution seam: `isExecutable` is injected so the rule can be tested without
    /// depending on whether the running machine has claude-swap installed.
    public static func resolve(
        configured: String?,
        defaultPath: String = ClaudeSwapExecutableResolver.defaultExecutablePath,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String
    {
        let trimmed = (configured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return isExecutable(defaultPath) ? defaultPath : ""
    }
}
