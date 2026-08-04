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
        _ = UserProviderPluginRegistry.refresh(loader: loader)
        self.settings.updateProviderState(config: self.settings.configSnapshot)
    }

    func refreshUserPlugin(_ instanceID: ProviderInstanceID) async {
        guard let plugin = UserProviderPluginRegistry.plugin(for: instanceID),
              self.settings.isPluginEnabled(instanceID)
        else {
            self.snapshots.removeValue(forKey: instanceID)
            self.errors.removeValue(forKey: instanceID)
            return
        }
        self.refreshingProviders.insert(instanceID)
        defer { self.refreshingProviders.remove(instanceID) }
        let config = self.settings.pluginConfig(instanceID)
        do {
            let snapshot = try await plugin.fetchUsage(
                settings: config?.pluginSettings ?? [:],
                secrets: config?.pluginSecrets ?? [:],
                environment: self.environmentBase,
                approvalStore: self.pluginApprovalStore,
                instanceCookieResolver: UserProviderPluginCookieBroker.resolver(
                    browserDetection: self.browserDetection))
            self.snapshots[instanceID] = snapshot
            self.errors[instanceID] = nil
            self.lastSourceLabels[instanceID] = plugin.fileURL.pathExtension.lowercased()
        } catch {
            self.errors[instanceID] = error.localizedDescription
        }
    }

    func approveUserPlugin(_ plugin: UserProviderPlugin) throws {
        let settings = self.settings.pluginConfig(plugin.manifest.id)?.pluginSettings ?? [:]
        try self.pluginApprovalStore.record(plugin.approvalBinding(settings: settings))
    }

    func deleteUserPlugin(_ plugin: UserProviderPlugin) throws {
        var config = self.settings.configSnapshot
        try UserProviderPluginManager.delete(
            plugin,
            approvalStore: self.pluginApprovalStore,
            config: &config,
            historyDirectory: self.planUtilizationHistoryStore.directoryURL)
        self.settings.replaceConfigAfterPluginDeletion(config)
        self.snapshots.removeValue(forKey: plugin.manifest.id)
        self.errors.removeValue(forKey: plugin.manifest.id)
        self.lastSourceLabels.removeValue(forKey: plugin.manifest.id)
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
