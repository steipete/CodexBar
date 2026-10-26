import CodexBarCore
import Foundation

extension UsageStore {
    /// Publishes (or, when `shareUsageWithCLI` is off, withdraws) the private usage cache that SSH `codexbar usage`
    /// runs fall back to. File I/O runs off the main actor, in order.
    func persistCLIUsageCache() {
        // Tests must never touch the real Application Support directory; they opt in with an injected URL.
        guard !SettingsStore.isRunningTests || self.cliUsageCacheURL != nil else { return }
        let url = self.cliUsageCacheURL ?? CLIUsageCache.defaultURL()
        let entries: [CLIUsageCache.Entry]? = self.settings.config.shareUsageWithCLI
            ? self.enabledFirstPartyProvidersForDisplay().compactMap { provider in
                // Only the default/system account matches what the CLI fetches itself.
                // Provider-specific by design: Codex managed/profile-home accounts differ from the CLI's live one.
                // Real snapshots only: the presentation snapshot can be a fabricated placeholder.
                guard self.settings.effectiveSelectedTokenAccount(for: provider) == nil,
                      !self.tokenAccountLiveStateProviders.contains(provider.instanceID),
                      provider != .codex || (self.settings.codexActiveSource == .liveSystem &&
                          self.lastCodexUsagePublicationGuard?.source == .liveSystem),
                      let snapshot = self.snapshot(for: provider.instanceID)
                else { return nil }
                return CLIUsageCache.Entry(provider: provider, usage: snapshot)
            }
            : nil
        let previous = self.cliUsageCachePersistTask
        self.cliUsageCachePersistTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            guard let entries else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                try CLIUsageCache.write(CLIUsageCache(entries: entries), to: url)
            } catch {
                CodexBarLog.logger(LogCategories.app).error(
                    "CLI usage cache write failed",
                    metadata: ["error": error.localizedDescription])
            }
        }
    }
}
