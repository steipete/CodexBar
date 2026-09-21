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
            }
        }
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
                instanceCookieResolver: UserProviderPluginCookieBroker.resolver(
                    browserDetection: self.browserDetection))
            guard canPublish() else { return }
            self.snapshots[instanceID] = snapshot
            self.errors[instanceID] = nil
            self.lastSourceLabels[instanceID] = plugin.fileURL.pathExtension.lowercased()
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
}

extension SettingsStore {
    func replaceConfigAfterPluginDeletion(_ replacement: CodexBarConfig) {
        self.updateConfig(reason: "plugin-delete", affectsBackgroundWork: true) { config in
            config = replacement
        }
    }
}
#endif
