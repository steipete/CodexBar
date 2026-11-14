import CodexBarCore
import Foundation

@MainActor
extension SpendDashboardSource {
    static func approvedStatisticsPlugins(store: UsageStore) -> [UserProviderPlugin] {
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

    static func statisticsPlugins(store: UsageStore) -> [UserProviderPlugin] {
        self.approvedStatisticsPlugins(store: store).filter { plugin in
            store.userPluginTokenPublication(plugin)?.snapshot != nil ||
                store.snapshots[plugin.manifest.id]?.costUsage != nil
        }
    }

    static func pluginOwnership(store: UsageStore) -> [String] {
        self.statisticsPlugins(store: store).map { plugin in
            let id = plugin.manifest.id
            return "\(id.rawValue):\(store.userPluginStatisticsScope(plugin)):" +
                "\(store.settings.providerConfigRevision(forInstanceID: id))"
        }
    }

    static func pluginRevisions(store: UsageStore) -> [String] {
        self.statisticsPlugins(store: store).map { plugin in
            let id = plugin.manifest.id.rawValue
            guard let publication = store.userPluginTokenPublication(plugin) else { return "\(id):unavailable" }
            guard let snapshot = publication.snapshot else { return "\(id):empty" }
            return "\(id):snapshot:\(self.snapshotRevision(snapshot))"
        }
    }

    static func capturePluginInputs(store: UsageStore) -> [SpendDashboardModel.ProviderInput] {
        self.statisticsPlugins(store: store).compactMap { plugin in
            guard let snapshot = store.userPluginTokenPublication(plugin)?.snapshot else { return nil }
            // Manifest labels are public plugin metadata. Account identity and config never enter this model.
            let name = ShareStatsSanitizer.providerName(plugin.manifest.name) ?? "Community plugin"
            return SpendDashboardModel.ProviderInput(
                providerID: plugin.manifest.id,
                displayName: name,
                snapshot: snapshot,
                sourceKind: .communityPlugin)
        }
    }
}

@MainActor
extension UsageStore {
    func userPluginStatisticsScope(_ plugin: UserProviderPlugin) -> String {
        let enablement = self.settings.providerEnablementRevision(forInstanceID: plugin.manifest.id)
        return "\(ObjectIdentifier(plugin.runtime)):\(enablement)"
    }

    func userPluginTokenPublication(_ plugin: UserProviderPlugin) -> TokenSnapshotPublication? {
        let id = plugin.manifest.id
        guard self.settings.isPluginEnabled(id),
              UserProviderPluginRegistry.plugin(for: id)?.runtime === plugin.runtime,
              let binding = try? plugin
                  .approvalBinding(settings: self.settings.pluginConfig(id)?.pluginSettings ?? [:]),
                  self.pluginApprovalStore.isApproved(binding),
                  let publication = self.tokenSnapshotPublications[id],
                  publication.providerConfigRevision == self.settings.providerConfigRevision(forInstanceID: id),
                  publication.scopeSignature == self.userPluginStatisticsScope(plugin)
        else { return nil }
        return publication
    }

    func publishUserPluginStatistics(_ snapshot: CostUsageTokenSnapshot?, plugin: UserProviderPlugin) {
        let id = plugin.manifest.id
        self.tokenSnapshotPublicationRevisions[id, default: 0] &+= 1
        self.tokenSnapshotPublications[id] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevisions[id] ?? 0,
            providerConfigRevision: self.settings.providerConfigRevision(forInstanceID: id),
            scopeSignature: self.userPluginStatisticsScope(plugin),
            accounting: nil)
    }

    func invalidateUserPluginStatistics(_ id: ProviderInstanceID) {
        self.tokenSnapshotPublications.removeValue(forKey: id)
        self.tokenSnapshotPublicationRevisions[id, default: 0] &+= 1
    }
}
