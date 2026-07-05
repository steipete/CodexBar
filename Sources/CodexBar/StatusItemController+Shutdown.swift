import AppKit

extension StatusItemController {
    func prepareForAppShutdown() {
        guard !self.hasPreparedForAppShutdown else { return }
        self.hasPreparedForAppShutdown = true
        #if DEBUG
        self.isReleasedForTesting = true
        #endif

        let openMenus = Array(self.openMenus.values)
        for menu in openMenus {
            menu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(menu)
        }

        self.cancelShutdownTasks()
        self.clearShutdownMenuState()
        self.removeShutdownStatusItems()
        self.creditsPurchaseWindow?.close()
        self.creditsPurchaseWindow = nil
    }

    private func cancelShutdownTasks() {
        self.blinkTask?.cancel()
        self.blinkTask = nil
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil
        self.loginTask?.cancel()
        self.loginTask = nil
        for task in self.manualRefreshTasks.values {
            task.cancel()
        }
        self.manualRefreshTasks.removeAll()
        self.menuCardRefreshMonitor.resetManualRefresh()
        self.screenChangeVisibilityTask?.cancel()
        self.screenChangeVisibilityTask = nil
        self.pendingScreenChangePreviousCount = nil
        self.animationDriver?.stop()
        self.animationDriver = nil
        self.animationPhase = 0
        self.blinkForceUntil = nil
        self.blinkStates.removeAll(keepingCapacity: false)
        self.blinkAmounts.removeAll(keepingCapacity: false)
        self.wiggleAmounts.removeAll(keepingCapacity: false)
        self.tiltAmounts.removeAll(keepingCapacity: false)
        self.quotaWarningFlashUntil.removeAll(keepingCapacity: false)
        for task in self.quotaWarningFlashTasks.values {
            task.cancel()
        }
        self.quotaWarningFlashTasks.removeAll(keepingCapacity: false)

        for task in self.menuRefreshTasks.values {
            task.cancel()
        }
        self.cancelAllClosedMenuRebuilds()
        for task in self.openMenuRebuildTasks.values {
            task.cancel()
        }
        self.openMenuInvalidationRetryTask?.cancel()
        self.openMenuInvalidationRetryTask = nil
        self.codexAccountMenuProjectionRevalidationTask?.cancel()
        self.codexAccountMenuProjectionRevalidationTask = nil
        self.providerSelectionUIRefreshTask?.cancel()
        self.providerSelectionUIRefreshTask = nil
        self.deferredMergedIconRenderAfterTracking = false
        self.providerSwitcherPointerInteractionMenuID = nil
        self.pendingProviderSwitcherPointerRebuild = nil
    }

    private func clearShutdownMenuState() {
        self.removeProviderSwitcherShortcutMonitor()
        self.menuRefreshTasks.removeAll(keepingCapacity: false)
        self.closedMenuRebuildTasks.removeAll(keepingCapacity: false)
        self.closedMenuRebuildRequests.cancelAll()
        self.openMenuRebuildTasks.removeAll(keepingCapacity: false)
        self.openMenuRebuildRequests.cancelAll()
        self.openMenuRebuildsClosingHostedSubviewMenus.removeAll(keepingCapacity: false)
        self.menuSession.clearMenuTracking()
        self.openMenus.removeAll(keepingCapacity: false)
        self.highlightedMenuItems.removeAll(keepingCapacity: false)
        self.menuCardHeightCache.removeAll(keepingCapacity: false)
        self.measuredStandardMenuWidthCache.removeAll(keepingCapacity: false)
        self.mergedSwitcherContentCaches.removeAll(keepingCapacity: false)
        self.menuProviders.removeAll(keepingCapacity: false)
        self.menuReadinessSignatures.removeAll(keepingCapacity: false)
        self.menuIdentitySignatures.removeAll(keepingCapacity: false)
        self.providerMenus.removeAll(keepingCapacity: false)
        self.mergedMenu = nil
        self.fallbackMenu = nil
    }

    private func removeShutdownStatusItems() {
        self.statusItem.menu = nil
        self.statusBar.removeStatusItem(self.statusItem)

        for item in self.statusItems.values {
            item.menu = nil
            self.statusBar.removeStatusItem(item)
        }
        self.statusItems.removeAll(keepingCapacity: false)
        self.lastAppliedProviderIconRenderSignatures.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    func releaseStatusItemsForTesting() {
        self.prepareForAppShutdown()
    }
    #endif
}
