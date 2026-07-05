import CodexBarCore
import Foundation

extension UsageStore {
    /// True when the opt-in claude-swap adapter should run alongside the
    /// ambient Claude refresh. The adapter is display-only: it never reads
    /// credentials and its failures never affect the ambient Claude snapshot.
    func shouldFetchClaudeSwapAccounts() -> Bool {
        self.settings.claudeSwapEnabled &&
            !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearClaudeSwapAccountState() {
        self.claudeSwapAccountSnapshots = []
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
    }

    func refreshClaudeSwapAccounts(generation: UInt64? = nil) async {
        let executablePath = self.settings.claudeSwapExecutablePath
        await self.probeClaudeSwapVersionIfNeeded(executablePath: executablePath)

        do {
            let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: executablePath)
            let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list)
            guard self.isCurrentProviderRefreshGeneration(.claude, generation: generation) else { return }
            self.claudeSwapAccountSnapshots = snapshots
            self.claudeSwapLastRefreshAt = Date()
            self.claudeSwapLastError = nil
        } catch {
            guard self.isCurrentProviderRefreshGeneration(.claude, generation: generation) else { return }
            // Retain the last successful snapshots as stale data; the settings
            // pane surfaces the adapter error and last refresh time.
            self.claudeSwapLastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapVersionProbedPath != executablePath else { return }
        let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath)
        self.claudeSwapVersionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }
}
