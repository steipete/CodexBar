import CodexBarCore
import Foundation

enum ClaudeSwapSwitchPhase: Equatable, Sendable {
    case activating
    case reconciling
}

/// External credential transactions must run to completion; configuration changes hide their state but do not
/// cancel the subprocess halfway through a claude-swap transaction.
struct ClaudeSwapTransientState {
    var lastError: String?
    var lastErrorAccountID: ProviderAccountIdentity?
    var switchingAccountID: ProviderAccountIdentity?
    var switchPhase: ClaudeSwapSwitchPhase?
    var task: Task<Void, Never>?
    var configurationGeneration: UInt64 = 0
    var versionProbedPath: String?
    var versionProbeGeneration: UInt64 = 0
}

extension UsageStore {
    /// True when the opt-in claude-swap adapter should run alongside the
    /// ambient Claude refresh. Listing is read-only; explicit account activation
    /// stays external-process-owned and never exposes credentials to CodexBar.
    func shouldFetchClaudeSwapAccounts() -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The active claude-swap account's usage snapshot when the adapter owns Claude
    /// account presentation (issue #2731: with two accounts the menu shows adapter
    /// cards while the bar rendered the ambient snapshot, which can have no usable
    /// windows). Returns nil — keep the ambient snapshot — when the adapter is below
    /// its presentation threshold or the active account reports no usable usage.
    ///
    /// A last-known measurement is deliberately not eligible here. Account cards
    /// state a snapshot's age, but the bar icon has no such affordance and
    /// `isStale` tracks provider errors rather than measurement age, so serving
    /// last-known numbers on the bar would present them as current.
    func claudeSwapMenuBarSnapshotOverride(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        guard instanceID == UsageProvider.claude.instanceID else { return nil }
        guard ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: .claude,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        else { return nil }
        guard let active = self.claudeSwapAccountSnapshots.first(where: \.isActive),
              !active.usesLastKnownUsage
        else { return nil }
        return active.snapshot
    }

    func clearClaudeSwapAccountState() {
        let hadState = !self.claudeSwapAccountSnapshots.isEmpty ||
            self.claudeSwapLastRefreshAt != nil || self.claudeSwapLastError != nil ||
            self.claudeSwapTransientState.lastError != nil ||
            self.claudeSwapTransientState.lastErrorAccountID != nil ||
            self.claudeSwapTransientState.switchingAccountID != nil ||
            self.claudeSwapTransientState.switchPhase != nil ||
            self.claudeSwapTransientState.versionProbedPath != nil ||
            self.claudeSwapDetectedVersion != nil
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapRefreshTask = nil
        self.claudeSwapAccountSnapshots = []
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
        self.claudeSwapTransientState = ClaudeSwapTransientState(
            task: self.claudeSwapTransientState.task,
            configurationGeneration: self.claudeSwapTransientState.configurationGeneration &+ 1,
            versionProbeGeneration: self.claudeSwapTransientState.versionProbeGeneration &+ 1)
        self.claudeSwapDetectedVersion = nil
        if hadState {
            self.claudeSwapRevision &+= 1
            if self.settings.accountWidgetsEnabled {
                self.persistWidgetSnapshot(reason: "claude-swap-accounts")
            }
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
            let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: ClaudeSwapRetainedUsageStore.previousAccounts(
                    inMemory: self.claudeSwapAccountSnapshots))
            guard self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: generation) else {
                return
            }
            ClaudeSwapRetainedUsageStore.save(snapshots)
            self.claudeSwapAccountSnapshots = snapshots
            self.claudeSwapLastRefreshAt = Date()
            self.claudeSwapLastError = nil
            self.claudeSwapRevision &+= 1
            if self.settings.accountWidgetsEnabled {
                self.persistWidgetSnapshot(reason: "claude-swap-accounts")
            }
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
    func switchClaudeSwapAccount(
        _ accountID: ProviderAccountIdentity,
        progressDidChange: (@MainActor () -> Void)? = nil)
    {
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
        let configurationGeneration = self.claudeSwapTransientState.configurationGeneration
        self.claudeSwapTransientState.switchingAccountID = accountID
        self.claudeSwapTransientState.switchPhase = .activating
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
            if self.isCurrentClaudeSwapConfiguration(
                executablePath: executablePath,
                configurationGeneration: configurationGeneration)
            {
                self.claudeSwapTransientState.lastError = switchError
                self.claudeSwapTransientState.lastErrorAccountID = switchError == nil ? nil : accountID
                self.claudeSwapTransientState.switchPhase = .reconciling
                self.claudeSwapRevision &+= 1
                progressDidChange?()
                // Claude Code owns the ambient credential, so reconcile both
                // the provider snapshot and the adapter's active-row marker.
                let previousAdapterTask = self.claudeSwapRefreshTask
                let ambient = Task { await self.refreshProvider(.claude) }
                // Cancel only the waiter: cancelling refreshProvider would cancel its provider request too.
                let waiter = Task<Void, Error> { await ambient.value }
                if case .timedOut = await BoundedTaskJoin(sourceTask: waiter).value(joinGrace: .seconds(5)),
                   self.isCurrentClaudeSwapConfiguration(
                       executablePath: executablePath,
                       configurationGeneration: configurationGeneration),
                   self.claudeSwapRefreshTask == previousAdapterTask
                {
                    // A stalled predecessor can prevent the ambient refresh from scheduling its adapter read.
                    self.scheduleClaudeSwapAccountRefresh()
                }
                // The ambient refresh schedules this independent read; a replacement read still owns reconciliation.
                while self.isCurrentClaudeSwapConfiguration(
                    executablePath: executablePath,
                    configurationGeneration: configurationGeneration),
                    let adapterTask = self.claudeSwapRefreshTask
                {
                    await adapterTask.value
                    if self.claudeSwapRefreshTask == adapterTask { break }
                }
            }
            let isCurrent = self.isCurrentClaudeSwapConfiguration(
                executablePath: executablePath,
                configurationGeneration: configurationGeneration)
            let currentError = isCurrent ? switchError : nil
            self.claudeSwapTransientState.task = nil
            self.claudeSwapTransientState.switchingAccountID = nil
            self.claudeSwapTransientState.switchPhase = nil
            self.claudeSwapTransientState.lastError = currentError
            self.claudeSwapTransientState.lastErrorAccountID = currentError == nil ? nil : accountID
            self.claudeSwapRevision &+= 1
            if isCurrent { progressDidChange?() }
        }
        progressDidChange?()
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapTransientState.versionProbedPath != executablePath else { return }
        self.claudeSwapTransientState.versionProbeGeneration &+= 1
        let generation = self.claudeSwapTransientState.versionProbeGeneration
        guard let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath),
              self.claudeSwapTransientState.versionProbeGeneration == generation,
              self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: nil)
        else { return }
        self.claudeSwapTransientState.versionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }

    func isCurrentClaudeSwapRefresh(executablePath: String, generation: UInt64?) -> Bool {
        !Task.isCancelled &&
            self.isCurrentProviderRefreshGeneration(.claude, generation: generation) &&
            self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
    }

    func isCurrentClaudeSwapConfiguration(
        executablePath: String,
        configurationGeneration: UInt64? = nil) -> Bool
    {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            self.settings.claudeSwapExecutablePath == executablePath &&
            (configurationGeneration == nil ||
                self.claudeSwapTransientState.configurationGeneration == configurationGeneration)
    }
}
