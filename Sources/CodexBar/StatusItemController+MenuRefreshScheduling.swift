import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    func performMenuMutationWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updates()
    }

    @discardableResult
    func beginProviderSwitcherSettingsSuppression() -> Int {
        self.providerSwitcherSettingsSuppressionGeneration &+= 1
        let token = self.providerSwitcherSettingsSuppressionGeneration
        self.activeProviderSwitcherSettingsSuppressionGeneration = token
        self.providerSwitcherDeferredIconUpdatePending = false
        return token
    }

    func finishProviderSwitcherSettingsSuppression(
        _ token: Int?,
        menuWasRebuilt: Bool,
        menuWasInvalidated: Bool = false)
    {
        guard let active = self.activeProviderSwitcherSettingsSuppressionGeneration else { return }
        if let token, token != active { return }

        self.activeProviderSwitcherSettingsSuppressionGeneration = nil
        self.providerSwitcherSettingsObservationSuppressionsRemaining = max(
            self.providerSwitcherSettingsObservationSuppressionsRemaining,
            2)
        if !menuWasRebuilt, !menuWasInvalidated {
            self.menuContentVersion &+= 1
        }
        guard self.providerSwitcherDeferredIconUpdatePending else { return }
        self.providerSwitcherDeferredIconUpdatePending = false
        self.applyIcon(phase: nil)
    }

    func deferSettingsChangeDuringMenuTracking(
        reason: String,
        needsStatusItemRebuild: Bool,
        needsOpenMenuRefresh: Bool)
    {
        self.settingsChangeDeferredDuringMenuTracking = true
        self.deferredSettingsChangeNeedsStatusItemRebuild =
            self.deferredSettingsChangeNeedsStatusItemRebuild || needsStatusItemRebuild
        self.deferredSettingsChangeNeedsOpenMenuRefresh =
            self.deferredSettingsChangeNeedsOpenMenuRefresh || needsOpenMenuRefresh
        self.menuLogger.debug(
            "settings change deferred during menu tracking",
            metadata: [
                "needsOpenMenuRefresh": "\(needsOpenMenuRefresh)",
                "needsStatusItemRebuild": "\(needsStatusItemRebuild)",
                "openMenus": "\(self.openMenus.count)",
                "reason": reason,
            ])
    }

    func applyDeferredSettingsChangeAfterMenuTrackingIfNeeded() {
        guard self.openMenus.isEmpty else { return }
        let storeChangeDeferred = self.storeChangeDeferredDuringMenuTracking
        let storeChangeDeferredVersion = self.storeChangeDeferredMenuContentVersion
        let storeChangeObservationCount = self.storeChangeDeferredObservationCount
        self.storeChangeDeferredDuringMenuTracking = false
        self.storeChangeDeferredMenuContentVersion = nil
        self.storeChangeDeferredObservationCount = 0
        if storeChangeDeferred {
            self.observeStoreChanges()
        }
        guard self.settingsChangeDeferredDuringMenuTracking || storeChangeDeferred else { return }

        let needsStatusItemRebuild = self.deferredSettingsChangeNeedsStatusItemRebuild
        let needsOpenMenuRefresh = self.deferredSettingsChangeNeedsOpenMenuRefresh
        let settingsChangeDeferred = self.settingsChangeDeferredDuringMenuTracking
        self.settingsChangeDeferredDuringMenuTracking = false
        self.deferredSettingsChangeNeedsStatusItemRebuild = false
        self.deferredSettingsChangeNeedsOpenMenuRefresh = false
        let shouldInvalidateForStoreChange = storeChangeDeferred &&
            storeChangeDeferredVersion == self.menuContentVersion

        self.menuLogger.info(
            "deferred menu change applied after menu tracking",
            metadata: [
                "needsOpenMenuRefresh": "\(needsOpenMenuRefresh)",
                "needsStatusItemRebuild": "\(needsStatusItemRebuild)",
                "storeChangeDeferred": "\(storeChangeDeferred)",
                "storeObservationCount": "\(storeChangeObservationCount)",
            ])
        if settingsChangeDeferred || shouldInvalidateForStoreChange {
            self.invalidateMenus(refreshOpenMenus: needsOpenMenuRefresh)
        }
        if needsStatusItemRebuild {
            self.rebuildProviderStatusItems()
        }
        self.updateVisibility()
        self.updateIcons()
    }

    func deferRefreshStoreUntilMenuInteractionEnds(reason: String) {
        self.deferredMenuInteractionRefreshPending = true
        self.deferredMenuInteractionRefreshGeneration &+= 1
        self.deferredMenuInteractionRefreshTask?.cancel()
        self.deferredMenuInteractionRefreshTask = nil
        self.menuLogger.debug(
            "store refresh deferred until menu interaction ends",
            metadata: [
                "openMenus": "\(self.openMenus.count)",
                "reason": reason,
            ])
    }

    func scheduleDeferredRefreshStoreAfterMenuTrackingIfNeeded(reason: String) {
        guard self.openMenus.isEmpty else { return }
        guard self.deferredMenuInteractionRefreshPending else { return }
        guard self.deferredMenuInteractionRefreshTask == nil else { return }

        self.deferredMenuInteractionRefreshGeneration &+= 1
        let generation = self.deferredMenuInteractionRefreshGeneration
        self.deferredMenuInteractionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            guard self.deferredMenuInteractionRefreshGeneration == generation else { return }
            self.deferredMenuInteractionRefreshTask = nil
            guard self.openMenus.isEmpty else { return }
            self.deferredMenuInteractionRefreshPending = false
            guard !self.store.isRefreshing else { return }
            self.menuLogger.debug(
                "store refresh resumed after menu interaction",
                metadata: ["reason": reason])
            self.refreshStore(forceTokenUsage: false, refreshOpenMenusWhenComplete: false)
        }
    }

    func noteProviderSwitcherInteraction() {
        self.lastProviderSwitcherInteractionAt = Date()
    }

    func deferSwitcherMenuRebuildIfStillVisible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        settingsSuppressionToken: Int? = nil)
    {
        self.providerSwitcherUpdateToken &+= 1
        let updateToken = self.providerSwitcherUpdateToken
        let updatedMenu = self.updateOpenMenuForSwitcherSelectionImmediately(
            menu,
            provider: provider,
            token: updateToken)
        if updatedMenu {
            self.closeHostedSubviewMenusForParentSwitch()
            self.finishProviderSwitcherSettingsSuppression(
                settingsSuppressionToken,
                menuWasRebuilt: true)
            return
        }

        let updatedSwitcher = self.updateOpenMenuSwitcherSelectionIfPossible(menu)
        if updatedSwitcher {
            self.closeHostedSubviewMenusForParentSwitch()
            let menuWasInvalidated = self.deferOpenParentMenuMutationIfTracking(
                menu,
                provider: provider,
                reason: "provider-switch-selection")
            self.finishProviderSwitcherSettingsSuppression(
                settingsSuppressionToken,
                menuWasRebuilt: false,
                menuWasInvalidated: menuWasInvalidated)
            return
        }

        self.menuLogger.debug(
            "provider switch parent rebuild deferred during menu tracking",
            metadata: [
                "provider": provider?.rawValue ?? "overview",
                "token": "\(updateToken)",
            ])
        let menuWasInvalidated = self.deferOpenParentMenuMutationIfTracking(
            menu,
            provider: provider,
            reason: "provider-switch")
        if menuWasInvalidated {
            self.closeHostedSubviewMenusForParentSwitch()
        }
        self.finishProviderSwitcherSettingsSuppression(
            settingsSuppressionToken,
            menuWasRebuilt: false,
            menuWasInvalidated: menuWasInvalidated)
    }

    private func updateOpenMenuSwitcherSelectionIfPossible(_ menu: NSMenu) -> Bool {
        let menuID = ObjectIdentifier(menu)
        guard self.openMenus[menuID] != nil else { return false }
        guard !self.isHostedSubviewMenu(menu) else { return false }
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView else { return false }
        guard let selection = self.lastMergedSwitcherSelection else { return false }

        switcherView.updateSelection(selection)
        switcherView.updateQuotaIndicators()
        self.applyIcon(phase: nil)
        return true
    }

    private func updateOpenMenuForSwitcherSelectionImmediately(
        _ menu: NSMenu,
        provider: UsageProvider?,
        token: Int)
        -> Bool
    {
        let menuID = ObjectIdentifier(menu)
        guard self.openMenus[menuID] != nil else { return false }
        guard !self.isHostedSubviewMenu(menu) else { return false }
        guard menu.items.first?.view is ProviderSwitcherView else { return false }

        let startedAt = Date()
        let didUpdate = self.populateMenu(
            menu,
            provider: provider,
            mode: .preserveExistingSwitcherWidth)
        guard didUpdate else { return false }

        self.markMenuFresh(menu)
        self.applyIcon(phase: nil)
        let updateMs = Date().timeIntervalSince(startedAt) * 1000
        self.menuLogger.info(
            "provider switch content updated in tracked menu",
            metadata: [
                "provider": provider?.rawValue ?? "overview",
                "token": "\(token)",
                "updateMs": String(format: "%.1f", updateMs),
            ])
        return true
    }

    @discardableResult
    func updateTrackedOpenParentMenuContentIfPossible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        reason: String)
        -> Bool
    {
        let menuID = ObjectIdentifier(menu)
        guard self.openMenus[menuID] != nil else { return false }
        guard !self.isHostedSubviewMenu(menu) else { return false }
        guard !self.hasOpenHostedSubviewMenu() else { return false }

        let startedAt = Date()
        let didUpdate = self.populateMenu(menu, provider: provider, mode: .preserveExistingSwitcherWidth)
        guard didUpdate else {
            _ = self.deferOpenParentMenuMutationIfTracking(
                menu,
                provider: provider,
                reason: "\(reason)-incompatible")
            self.applyIcon(phase: nil)
            return false
        }

        self.markMenuFresh(menu)
        self.applyIcon(phase: nil)
        let updateMs = Date().timeIntervalSince(startedAt) * 1000
        self.menuLogger.info(
            "tracked parent menu content updated",
            metadata: [
                "provider": provider?.rawValue ?? "overview",
                "reason": reason,
                "updateMs": String(format: "%.1f", updateMs),
            ])
        #if DEBUG
        self._test_openMenuRebuildObserver?(menu)
        #endif
        return true
    }

    @discardableResult
    func deferOpenParentMenuMutationIfTracking(
        _ menu: NSMenu,
        provider: UsageProvider?,
        reason: String)
        -> Bool
    {
        let menuID = ObjectIdentifier(menu)
        guard self.openMenus[menuID] != nil else { return false }
        guard !self.isHostedSubviewMenu(menu) else { return false }

        self.openMenuRefreshTokens.removeValue(forKey: menuID)
        if self.menuVersions[menuID] == self.menuContentVersion {
            self.menuContentVersion &+= 1
        }
        self.menuLogger.debug(
            "open parent menu mutation deferred until next open",
            metadata: [
                "provider": provider?.rawValue ?? "overview",
                "reason": reason,
            ])
        return true
    }

    private func closeHostedSubviewMenusForParentSwitch() {
        let hostedMenus = self.openMenus.values.filter { self.isHostedSubviewMenu($0) }
        guard !hostedMenus.isEmpty else { return }
        self.closingHostedSubviewMenusForParentSwitch = true
        defer { self.closingHostedSubviewMenusForParentSwitch = false }
        for hostedMenu in hostedMenus {
            hostedMenu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(hostedMenu)
        }
    }
}
