import AppKit
import CodexBarCore
import Foundation

enum ProviderDetectionPolicy {
    struct Signals {
        let codexCLIInstalled: Bool
        let claudeCLIInstalled: Bool
        let claudeDesktopInstalled: Bool
        let geminiCLIInstalled: Bool
        let geminiConfigured: Bool
        let antigravityAvailable: Bool
    }

    static func enabledProviders(signals: Signals) -> Set<UsageProvider> {
        var enabled: Set<UsageProvider> = []
        if signals.codexCLIInstalled { enabled.insert(.codex) }
        if signals.claudeCLIInstalled || signals.claudeDesktopInstalled { enabled.insert(.claude) }
        if signals.geminiCLIInstalled, signals.geminiConfigured { enabled.insert(.gemini) }
        if signals.antigravityAvailable { enabled.insert(.antigravity) }

        // Keep the historical Codex default when no usable provider source is found.
        if enabled.isEmpty { enabled.insert(.codex) }
        return enabled
    }
}

extension SettingsStore {
    func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || !self.providerDetectionCompleted else { return }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection()
            }
        }
    }

    func applyProviderDetection() async {
        guard !self.providerDetectionCompleted else { return }
        let codexCLIInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeCLIInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let claudeDesktopInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        let geminiCLIInstalled = BinaryLocator.resolveGeminiBinary() != nil
        let geminiConfigured = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/oauth_creds.json").path)
        let antigravityRunning = await AntigravityStatusProbe.isRunning()
        let antigravityLoggedIn = FileManager.default.fileExists(
            atPath: AntigravityOAuthCredentialsStore().fileURL.path)
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        let enabledProviders = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: codexCLIInstalled,
            claudeCLIInstalled: claudeCLIInstalled,
            claudeDesktopInstalled: claudeDesktopInstalled,
            geminiCLIInstalled: geminiCLIInstalled,
            geminiConfigured: geminiConfigured,
            antigravityAvailable: antigravityRunning || antigravityLoggedIn))

        logger.info(
            "Provider detection results",
            metadata: [
                "codexCLIInstalled": codexCLIInstalled ? "1" : "0",
                "claudeCLIInstalled": claudeCLIInstalled ? "1" : "0",
                "claudeDesktopInstalled": claudeDesktopInstalled ? "1" : "0",
                "geminiCLIInstalled": geminiCLIInstalled ? "1" : "0",
                "geminiConfigured": geminiConfigured ? "1" : "0",
                "antigravityRunning": antigravityRunning ? "1" : "0",
                "antigravityLoggedIn": antigravityLoggedIn ? "1" : "0",
            ])
        logger.info(
            "Provider detection enablement",
            metadata: [
                "codex": enabledProviders.contains(.codex) ? "1" : "0",
                "claude": enabledProviders.contains(.claude) ? "1" : "0",
                "gemini": enabledProviders.contains(.gemini) ? "1" : "0",
                "antigravity": enabledProviders.contains(.antigravity) ? "1" : "0",
            ])

        self.updateProviderConfig(provider: .codex) { entry in
            entry.enabled = enabledProviders.contains(.codex)
        }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = enabledProviders.contains(.claude)
        }
        self.updateProviderConfig(provider: .gemini) { entry in
            entry.enabled = enabledProviders.contains(.gemini)
        }
        self.updateProviderConfig(provider: .antigravity) { entry in
            entry.enabled = enabledProviders.contains(.antigravity)
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }
}
