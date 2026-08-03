import AppKit
import CodexBarCore
import Observation

extension StatusItemController {
    func observeCloudSyncChanges() {
        withObservationTracking {
            _ = self.cloudSyncState.fleetDevices
            _ = self.cloudSyncState.fleetSnapshots
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeCloudSyncChanges()
                self.invalidateMenus(refreshOpenMenus: true)
            }
        }
    }

    func fleetAccountProjection(for provider: UsageProvider) -> FleetAccountMenuProjection {
        guard self.settings.iCloudSyncEnabled,
              self.settings.iCloudSyncSnapshotsEnabled,
              self.settings.iCloudSyncShowFleetAccounts
        else {
            return FleetAccountMenuProjection(fallback: nil, additionalAccounts: [])
        }
        let localSnapshots = self.store.cloudSyncAccountSnapshots()
        return FleetAccountMenuPlanner.projection(
            provider: provider,
            snapshots: self.cloudSyncState.fleetSnapshots.values,
            currentDeviceID: self.settings.iCloudSyncDeviceID,
            localAccountKeys: self.store.cloudSyncLocalAccountKeys(for: provider),
            hasLocalUsage: localSnapshots.contains(where: { $0.provider == provider }))
    }

    func addFleetAccountMenuCards(
        _ snapshots: [AccountSnapshotSyncPayload],
        to menu: NSMenu,
        context: MenuCardContext)
    {
        guard !snapshots.isEmpty else { return }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        for (index, snapshot) in snapshots.enumerated() {
            guard let model = self.fleetAccountMenuCardModel(snapshot) else { continue }
            menu.addItem(self.makeMenuCardItem(
                FleetAccountMenuCardView(model: model, width: context.menuWidth),
                id: "fleetAccount-\(snapshot.accountKey)",
                width: context.menuWidth,
                heightCacheScope: "fleet-\(context.currentProvider.rawValue)-\(snapshot.accountKey)",
                heightCacheFingerprint: model.heightFingerprint(section: "fleetAccount"),
                containsInteractiveControls: false))
            if index < snapshots.count - 1 {
                menu.addItem(.separator())
            }
        }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
    }

    func addFleetFallback(
        _ projection: FleetAccountMenuProjection,
        to menu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        guard let fallback = projection.fallback else { return false }
        self.addFleetAccountMenuCards(
            [fallback] + projection.additionalAccounts,
            to: menu,
            context: context)
        return true
    }

    func fleetAccountMenuCardModel(
        _ snapshot: AccountSnapshotSyncPayload) -> UsageMenuCardView.Model?
    {
        let deviceName = self.cloudSyncState.fleetDevices.values
            .first(where: { $0.deviceID == snapshot.deviceID })?
            .hostName ?? L("another Mac")
        let badge = FleetAccountMenuPlanner.badge(deviceName: deviceName, fetchedAt: snapshot.fetchedAt)
        let label = snapshot.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.menuCardModel(
            for: snapshot.provider,
            snapshotOverride: snapshot.usage,
            forceOverrideCard: true,
            accountOverride: AccountInfo(email: label.isEmpty ? nil : label, plan: nil),
            subtitleOverride: badge)
    }
}
