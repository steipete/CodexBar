import CodexBarCore
import Foundation

@MainActor
extension SpendDashboardSource {
    static func pluginInputs(store: UsageStore) -> [SpendDashboardModel.ProviderInput] {
        guard store.settings.costUsageEnabled else { return [] }
        return UserProviderPluginRegistry.all.compactMap { plugin in
            let id = plugin.manifest.id
            guard store.settings.isPluginEnabled(id),
                  let publication = store.tokenSnapshotPublications[id],
                  publication.providerConfigRevision == store.settings.providerConfigRevision(forInstanceID: id),
                  publication.scopeSignature == store.userPluginStatisticsScope(plugin),
                  let binding = try? plugin
                      .approvalBinding(settings: store.settings.pluginConfig(id)?.pluginSettings ?? [:]),
                      store.pluginApprovalStore.isApproved(binding),
                      let snapshot = publication.snapshot
            else { return nil }
            return SpendDashboardModel.ProviderInput(
                id: "plugin/\(id.rawValue)",
                providerID: id,
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
