#if canImport(JavaScriptCore)
import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func isEnabledProviderInstance(_ instanceID: ProviderInstanceID, now: Date) -> Bool {
        if let provider = instanceID.firstPartyProvider {
            return self.isProviderAvailable(provider, now: now)
        }
        return UserProviderPluginRegistry.plugin(for: instanceID) != nil
    }

    func refreshUserPluginDiscovery(loader: UserProviderPluginLoader = UserProviderPluginLoader()) {
        let previous = UserProviderPluginRegistry.all
        _ = UserProviderPluginRegistry.refresh(loader: loader)
        self.settings.updateProviderState(config: self.settings.configSnapshot)
        for plugin in previous {
            guard let current = UserProviderPluginRegistry.plugin(for: plugin.manifest.id) else {
                self.clearUserPluginState(plugin.manifest.id)
                continue
            }
            if current.runtime !== plugin.runtime {
                self.providerRefreshCoordinator.invalidateRequests(for: plugin.manifest.id)
                self.clearUserPluginHookState(plugin.manifest.id)
            }
        }
        self.pruneUserPluginHookState()
    }

    func refreshUserPlugin(_ instanceID: ProviderInstanceID) async {
        guard !Task.isCancelled, instanceID.firstPartyProvider == nil else { return }
        guard UserProviderPluginRegistry.plugin(for: instanceID) != nil,
              self.settings.isPluginEnabled(instanceID)
        else {
            self.clearUserPluginState(instanceID)
            return
        }

        let request = self.providerRefreshCoordinator.beginReplacingRequest(for: instanceID)
        self.providerRefreshCoordinator.beginActivity(for: instanceID)
        self.refreshingProviders.insert(instanceID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.providerRefreshCoordinator.endActivity(for: instanceID) {
                    self.refreshingProviders.remove(instanceID)
                }
            }
            for predecessor in request.predecessorStates {
                await predecessor.waitForTaskCompletion()
            }
            if !Task.isCancelled,
               self.providerRefreshCoordinator.isCurrent(request.generation, for: instanceID),
               self.settings.isPluginEnabled(instanceID),
               let plugin = UserProviderPluginRegistry.plugin(for: instanceID)
            {
                await self.refreshUserPluginPass(plugin, generation: request.generation)
            }
            self.providerRefreshCoordinator.complete(request.state, for: instanceID, retryRequired: false)
        }
        request.state.install(task: task)
        _ = await self.providerRefreshCoordinator.wait(for: instanceID, state: request.state)
    }

    private func refreshUserPluginPass(_ plugin: UserProviderPlugin, generation: UInt64) async {
        let instanceID = plugin.manifest.id
        let enablementRevision = self.settings.providerEnablementRevision(forInstanceID: instanceID)
        let configRevision = self.settings.providerConfigRevision(forInstanceID: instanceID)
        func canPublish() -> Bool {
            !Task.isCancelled &&
                self.providerRefreshCoordinator.isCurrent(generation, for: instanceID) &&
                self.settings.isPluginEnabled(instanceID) &&
                self.settings.providerEnablementRevision(forInstanceID: instanceID) == enablementRevision &&
                self.settings.providerConfigRevision(forInstanceID: instanceID) == configRevision &&
                UserProviderPluginRegistry.plugin(for: instanceID)?.runtime === plugin.runtime
        }

        let config = self.settings.pluginConfig(instanceID)
        do {
            let snapshot = try await plugin.fetchUsage(
                settings: config?.pluginSettings ?? [:],
                secrets: config?.pluginSecrets ?? [:],
                environment: self.environmentBase,
                approvalStore: self.pluginApprovalStore,
                browserDetection: self.browserDetection)
            guard canPublish() else { return }
            self.snapshots[instanceID] = snapshot
            self.errors[instanceID] = nil
            self.lastSourceLabels[instanceID] = plugin.fileURL.pathExtension.lowercased()
            self.emitUserPluginHooks(provider: instanceID, snapshot: snapshot)
        } catch {
            guard canPublish() else { return }
            self.errors[instanceID] = error.localizedDescription
        }
    }

    func clearUserPluginState(_ instanceID: ProviderInstanceID) {
        self.providerRefreshCoordinator.invalidateRequests(for: instanceID)
        self.refreshingProviders.remove(instanceID)
        self.snapshots.removeValue(forKey: instanceID)
        self.errors.removeValue(forKey: instanceID)
        self.lastSourceLabels.removeValue(forKey: instanceID)
        self.clearUserPluginHookState(instanceID)
    }

    func deleteUserPlugin(_ plugin: UserProviderPlugin) throws {
        var config = self.settings.configSnapshot
        try UserProviderPluginManager.delete(
            plugin,
            approvalStore: self.pluginApprovalStore,
            config: &config,
            historyDirectory: self.planUtilizationHistoryStore.directoryURL)
        self.settings.replaceConfigAfterPluginDeletion(config)
        self.clearUserPluginState(plugin.manifest.id)
        self.refreshUserPluginDiscovery()
    }

    func emitUserPluginHooks(provider: ProviderInstanceID, snapshot: UsageSnapshot) {
        self.resetQuotaLowHookUsageIfConfigurationChanged()
        let account = Self.hookAccountDiscriminator(provider: provider, snapshot: snapshot)
        let displayName = self.hookAccountDisplayName(provider: provider, snapshot: snapshot)
        self.emitUsageUpdatedHook(provider: provider, snapshot: snapshot)
        if self.hasQuotaHookRule(event: .quotaLow, provider: provider) {
            for (lane, window) in [(QuotaWarningWindow.session, snapshot.primary), (.weekly, snapshot.secondary)] {
                self.dispatchQuotaLowHooks(
                    provider: provider,
                    lane: QuotaLowHookLane(window: lane, windowID: nil, label: lane.displayName),
                    rateWindow: window?.measured,
                    accountDiscriminator: account,
                    accountDisplayName: displayName)
            }
        } else {
            self.clearQuotaLowHookUsage(provider: provider)
        }

        let session = snapshot.primary?.measured.flatMap { Self.isSessionWindow($0) ? $0 : nil }
        if let session {
            let evaluation = SessionQuotaTransitionReducer.evaluate(
                previous: self.sessionQuotaTransitionStates[provider],
                observation: SessionQuotaTransitionObservation(
                    provider: provider,
                    remaining: session.remainingPercent,
                    source: .primary,
                    resetBoundary: session.resetsAt,
                    observedAt: snapshot.updatedAt,
                    evaluationTime: Date(),
                    accountDiscriminator: account),
                notificationsEnabled: self.hasQuotaHookRule(event: .quotaReached, provider: provider))
            self.sessionQuotaTransitionStates[provider] = evaluation.state
            if evaluation.outcome == .depleted {
                self.emitQuotaReachedHook(provider: provider, sessionWindow: (session, .primary), snapshot: snapshot)
            }
        } else {
            self.sessionQuotaTransitionStates.removeValue(forKey: provider)
        }

        let key = Self.limitResetDetectorStateKey(
            provider: provider,
            accountIdentifier: account.map { Self.sha256Hex("\(provider.rawValue):\($0)") } ?? provider.rawValue)
        let resetSession = session.flatMap { Self.isSemanticSessionResetWindow(($0, .primary)) ? $0 : nil }
        let weekly = Self.genericSessionEquivalentWindowComponents(snapshot: snapshot).weekly?.window.measured
        for (series, window) in [(PlanUtilizationSeriesName.session, resetSession), (.weekly, weekly)] {
            guard let window else { continue }
            let previous = series == .session
                ? self.sessionLimitResetDetectorStates[key] : self.weeklyLimitResetDetectorStates[key]
            guard previous.map({ snapshot.updatedAt > $0.lastObservedAt }) ?? true else { continue }
            let transition = Self.limitResetDetectorTransition(input: LimitResetDetectorTransitionInput(
                provider: provider,
                snapshot: snapshot,
                seriesName: series,
                observation: LimitResetObservation(
                    usedPercent: window.usedPercent,
                    observedAt: snapshot.updatedAt,
                    resetBoundary: window.resetsAt,
                    source: series == .session ? .primary : nil),
                previousState: previous,
                requiresLowConfirmation: false))
            if series == .session {
                self.sessionLimitResetDetectorStates[key] = transition.state
            } else {
                self.weeklyLimitResetDetectorStates[key] = transition.state
            }
            if transition.shouldPost {
                self.emitQuotaResetHook(
                    provider: provider,
                    window: series == .session ? .session : .weekly,
                    usedPercent: window.usedPercent,
                    accountLabel: displayName)
            }
        }
        self.persistUserPluginResetStates()
    }

    func clearUserPluginHookState(_ provider: ProviderInstanceID) {
        self.clearQuotaLowHookUsage(provider: provider)
        self.sessionQuotaTransitionStates.removeValue(forKey: provider)
        let prefix = provider.rawValue + ":"
        self.sessionLimitResetDetectorStates = self.sessionLimitResetDetectorStates.filter { !$0.key.hasPrefix(prefix) }
        self.weeklyLimitResetDetectorStates = self.weeklyLimitResetDetectorStates.filter { !$0.key.hasPrefix(prefix) }
        self.persistUserPluginResetStates()
    }

    func pruneUserPluginHookState() {
        let resetIDs = (Array(self.sessionLimitResetDetectorStates.keys)
            + Array(self.weeklyLimitResetDetectorStates.keys)).compactMap { key in
            key.split(separator: ":", maxSplits: 1).first.flatMap { ProviderInstanceID(rawValue: String($0)) }
        }
        let ids = Set(resetIDs).union(self.sessionQuotaTransitionStates.keys)
            .union(self.quotaLowHookUsage.keys.map(\.provider))
        for id in ids where id.firstPartyProvider == nil {
            if UserProviderPluginRegistry.plugin(for: id) == nil || !self.settings.isPluginEnabled(id) {
                self.clearUserPluginHookState(id)
            }
        }
    }

    private func persistUserPluginResetStates() {
        self.persistPlanUtilizationStates(
            self.sessionLimitResetDetectorStates,
            defaultsKey: Self.sessionLimitResetDetectorDefaultsKey,
            logName: "session")
        self.persistPlanUtilizationStates(
            self.weeklyLimitResetDetectorStates,
            defaultsKey: Self.weeklyLimitResetDetectorDefaultsKey,
            logName: "weekly")
    }
}

extension SettingsStore {
    func replaceConfigAfterPluginDeletion(_ replacement: CodexBarConfig) {
        self.updateConfig(reason: "plugin-delete", affectsBackgroundWork: true) { config in
            config = replacement
        }
    }
}
#endif
