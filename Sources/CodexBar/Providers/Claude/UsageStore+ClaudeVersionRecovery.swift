import CodexBarCore
import Foundation

extension UsageStore {
    /// #2899: the startup version probe runs in a detached background task, where the Claude
    /// opaque-child gate denies `claude --version` on a cold profile. A successful user-initiated
    /// CLI usage fetch proves the same resolved binary works, so re-run only the Claude version
    /// probe in that user-initiated context while the version is still missing.
    func refreshClaudeVersionAfterUserInitiatedCLIFetch(
        provider: UsageProvider,
        strategyKind: ProviderFetchKind)
    {
        // Provider-specific by design: only Claude's gated version probe recovers from a user-initiated CLI success.
        guard provider == .claude,
              strategyKind == .cli,
              ProviderInteractionContext.current == .userInitiated,
              self.versions[provider.instanceID] == nil,
              self.claudeVersionRefreshTask == nil,
              let implementation = ProviderCatalog.all.first(where: { $0.id == .claude })
        else { return }
        let context = ProviderVersionContext(provider: .claude, browserDetection: self.browserDetection)
        // Unstructured (not detached) so the user-initiated interaction task-local is inherited.
        self.claudeVersionRefreshTask = Task { @MainActor [weak self] in
            let version = await implementation.detectVersion(context: context)
            guard let self else { return }
            self.claudeVersionRefreshTask = nil
            guard let version, !version.isEmpty else { return }
            self.versions[UsageProvider.claude.instanceID] = version
        }
    }
}
