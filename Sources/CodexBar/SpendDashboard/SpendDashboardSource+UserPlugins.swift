import CodexBarCore
import Foundation

@MainActor
extension SpendDashboardSource {
    static func statisticsPlugins(store: UsageStore) -> [UserProviderPlugin] {
        guard store.settings.costUsageEnabled else { return [] }
        return UserProviderPluginRegistry.all.filter { plugin in
            let id = plugin.manifest.id
            guard store.settings.isPluginEnabled(id),
                  let binding = try? plugin
                      .approvalBinding(settings: store.settings.pluginConfig(id)?.pluginSettings ?? [:]),
                      store.pluginApprovalStore.isApproved(binding)
            else { return false }
            return true
        }
    }

    static func pluginPublication(_ plugin: UserProviderPlugin, store: UsageStore) -> TokenSnapshotPublication? {
        let id = plugin.manifest.id
        guard let publication = store.tokenSnapshotPublications[id],
              publication.providerConfigRevision == store.settings.providerConfigRevision(forInstanceID: id),
              publication.scopeSignature == store.userPluginStatisticsScope(plugin)
        else { return nil }
        return publication
    }

    static func pluginInputs(store: UsageStore) -> [SpendDashboardModel.ProviderInput] {
        self.statisticsPlugins(store: store).compactMap { plugin in
            guard let snapshot = self.pluginPublication(plugin, store: store)?.snapshot else { return nil }
            return SpendDashboardModel.ProviderInput(
                id: "plugin/\(plugin.manifest.id.rawValue)",
                providerID: plugin.manifest.id,
                displayName: plugin.manifest.name,
                snapshot: snapshot)
        }
    }
}

extension UsageStore {
    func userPluginStatisticsScope(_ plugin: UserProviderPlugin) -> String {
        let enablement = self.settings.providerEnablementRevision(forInstanceID: plugin.manifest.id)
        return "\(ObjectIdentifier(plugin.runtime)):\(enablement)"
    }
}
