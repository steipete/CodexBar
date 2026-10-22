import AppKit
import CodexBarCore
import Observation

extension StatusItemController {
    func observeCloudSyncChanges() {
        withObservationTracking {
            _ = self.cloudSyncState.fleetDevices
            _ = self.cloudSyncState.fleetSnapshots
            _ = self.settings.iCloudSyncEnabled
            _ = self.settings.iCloudSyncSnapshotsEnabled
            _ = self.settings.iCloudSyncShowFleetAccounts
            _ = self.settings.iCloudSyncDeviceID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeCloudSyncChanges()
                self.refreshForCloudSyncChange()
            }
        }
    }

    /// Presentation-only source for the status item: this Mac's usage wins; otherwise the same freshest
    /// fleet snapshot the menu falls back to. Remote data is never written into `UsageStore`.
    func menuBarUsageSource(for provider: UsageProvider) -> MenuBarUsageSource {
        let localSnapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        guard localSnapshot == nil,
              self.settings.isProviderEnabledCached(provider: provider, metadataByProvider: self.store.providerMetadata)
        else { return .local(localSnapshot) }
        // Match the menu's local-account authority, including inactive token/swap snapshots.
        return MenuBarUsageSource.resolve(
            localSnapshot: nil,
            fleetFallback: self.fleetAccountProjection(for: provider).fallback)
    }

    /// `store.isStale` reports this Mac's fetch failures, not a remote account's state. Fleet usage is
    /// explicitly last-known data; its capture timestamp is exposed in the source description instead.
    func menuBarIsStale(for provider: UsageProvider) -> Bool {
        !self.menuBarUsageSource(for: provider).isFleet && self.store.isStale(provider: provider)
    }

    func isRefreshingLocalMenuBarUsage(_ provider: UsageProvider) -> Bool {
        !self.menuBarUsageSource(for: provider).isFleet
            && self.store.refreshingProviders.contains(provider.instanceID)
    }

    func menuBarFleetSourceDescription(for provider: UsageProvider) -> String? {
        guard let snapshot = self.menuBarUsageSource(for: provider).fleetSnapshot else { return nil }
        let deviceName = self.settings.hidePersonalInfo ? L("another Mac") : self.cloudSyncState.fleetDevices.values
            .first(where: { $0.deviceID == snapshot.deviceID })?.hostName ?? L("another Mac")
        let timestamp = snapshot.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard)
            .locale(codexBarLocalizedResourceLocale()))
        return [L(self.store.metadata(for: provider).displayName), L("iCloud Sync"), deviceName, timestamp]
            .joined(separator: " · ")
    }

    func updateMenuBarSourceDescription(for button: NSButton, providers: [UsageProvider]) {
        let descriptions = providers.compactMap { self.menuBarFleetSourceDescription(for: $0) }
        let description = descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
        button.setAccessibilityHelp(description)
    }

    func menuBarLayoutWindows(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date) -> MenuBarLayoutWindows
    {
        self.store.menuBarLayoutWindows(
            provider: provider,
            snapshot: snapshot,
            includeLocalDerivedData: !self.menuBarUsageSource(for: provider).isFleet,
            now: now)
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
            hasLocalUsage: localSnapshots.contains(where: { $0.provider == provider.instanceID }))
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
        guard let provider = snapshot.provider.firstPartyProvider else { return nil }
        let deviceName = self.cloudSyncState.fleetDevices.values
            .first(where: { $0.deviceID == snapshot.deviceID })?
            .hostName ?? L("another Mac")
        let badge = FleetAccountMenuPlanner.badge(deviceName: deviceName, fetchedAt: snapshot.fetchedAt)
        let label = snapshot.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.menuCardModel(
            for: provider,
            context: .account(.init(
                snapshot: snapshot.usage,
                info: AccountInfo(email: label.isEmpty ? nil : label, plan: nil),
                subtitle: badge)))
    }
}
