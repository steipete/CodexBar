import CodexBarCore
import Foundation

/// External credential transactions must run to completion; configuration changes hide their state but do not
/// cancel the subprocess halfway through a claude-swap transaction.
struct ClaudeSwapTransientState {
    var lastError: String?
    var lastErrorAccountID: ProviderAccountIdentity?
    var switchingAccountID: ProviderAccountIdentity?
    var task: Task<Void, Never>?
    var versionProbedPath: String?
}

extension UsageStore {
    /// True when the opt-in claude-swap adapter should run alongside the
    /// ambient Claude refresh. Listing is read-only; explicit account activation
    /// stays external-process-owned and never exposes credentials to CodexBar.
    func shouldFetchClaudeSwapAccounts() -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearClaudeSwapAccountState() {
        let hadState = !self.claudeSwapAccountSnapshots.isEmpty ||
            self.claudeSwapLastRefreshAt != nil || self.claudeSwapLastError != nil ||
            self.claudeSwapTransientState.lastError != nil ||
            self.claudeSwapTransientState.lastErrorAccountID != nil ||
            self.claudeSwapTransientState.switchingAccountID != nil
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapRefreshTask = nil
        self.claudeSwapAccountSnapshots = []
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
        self.claudeSwapTransientState.lastError = nil
        self.claudeSwapTransientState.lastErrorAccountID = nil
        self.claudeSwapTransientState.switchingAccountID = nil
        if hadState {
            self.claudeSwapRevision &+= 1
        }
    }

    /// Runs the optional adapter independently so it cannot delay the ambient Claude card.
    func scheduleClaudeSwapAccountRefresh(generation: UInt64? = nil) {
        self.claudeSwapRefreshTask?.cancel()
        guard self.shouldFetchClaudeSwapAccounts() else {
            self.clearClaudeSwapAccountState()
            return
        }

        self.claudeSwapRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshClaudeSwapAccounts(generation: generation)
        }
    }

    func refreshClaudeSwapAccounts(generation: UInt64? = nil) async {
        let executablePath = self.settings.claudeSwapExecutablePath
        await self.probeClaudeSwapVersionIfNeeded(executablePath: executablePath)

        do {
            let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: executablePath)
            let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list)
            guard self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: generation) else {
                return
            }
            self.claudeSwapAccountSnapshots = snapshots
            self.claudeSwapLastRefreshAt = Date()
            self.claudeSwapLastError = nil
            self.claudeSwapRevision &+= 1
        } catch is CancellationError {
            return
        } catch {
            guard self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: generation) else {
                return
            }
            // Retain the last successful snapshots as stale data; the settings
            // pane surfaces the adapter error and last refresh time.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if self.claudeSwapLastError != message {
                self.claudeSwapLastError = message
                self.claudeSwapRevision &+= 1
            }
        }
    }

    /// Activates one account through the configured claude-swap executable.
    /// The numeric slot comes from the already validated list payload; requests
    /// are serialized so two credential transactions can never overlap.
    func switchClaudeSwapAccount(_ accountID: ProviderAccountIdentity) {
        guard self.claudeSwapTransientState.task == nil,
              self.shouldFetchClaudeSwapAccounts(),
              accountID.source == ClaudeSwapAccountProjection.sourceName,
              let account = self.claudeSwapAccountSnapshots.first(where: { $0.id == accountID }),
              account.canActivate,
              let accountNumber = Int(accountID.opaqueID),
              accountNumber > 0
        else {
            return
        }

        let executablePath = self.settings.claudeSwapExecutablePath
        self.claudeSwapTransientState.switchingAccountID = accountID
        self.claudeSwapTransientState.lastError = nil
        self.claudeSwapTransientState.lastErrorAccountID = nil
        self.claudeSwapRevision &+= 1

        self.claudeSwapTransientState.task = Task { @MainActor [weak self] in
            var switchError: String?
            do {
                _ = try await ClaudeSwapAccountReader.switchAccount(
                    executablePath: executablePath,
                    accountNumber: accountNumber)
            } catch {
                switchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard let self else { return }
            if self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) {
                // Claude Code owns the ambient credential, so reconcile both
                // the provider snapshot and the adapter's active-row marker.
                await self.refreshProvider(.claude)
            }
            let configurationIsCurrent = self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
            self.claudeSwapTransientState.task = nil
            self.claudeSwapTransientState.switchingAccountID = nil
            if configurationIsCurrent {
                self.claudeSwapTransientState.lastError = switchError
                self.claudeSwapTransientState.lastErrorAccountID = switchError == nil ? nil : accountID
            }
            self.claudeSwapRevision &+= 1
        }
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapTransientState.versionProbedPath != executablePath else { return }
        let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath)
        guard self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) else { return }
        self.claudeSwapTransientState.versionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }

    private func isCurrentClaudeSwapRefresh(executablePath: String, generation: UInt64?) -> Bool {
        self.isCurrentProviderRefreshGeneration(.claude, generation: generation) &&
            self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
    }

    private func isCurrentClaudeSwapConfiguration(executablePath: String) -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            self.settings.claudeSwapExecutablePath == executablePath
    }
}
