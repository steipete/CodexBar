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

    func deferSwitcherMenuRebuildIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        self.providerSwitcherUpdateToken &+= 1
        let updateToken = self.providerSwitcherUpdateToken
        self.scheduleOpenMenuRebuildIfStillVisible(
            menu,
            provider: provider,
            closeHostedSubviewMenusBeforeRebuild: true)
        { [weak self] in
            guard let self else { return false }
            return self.providerSwitcherUpdateToken == updateToken
        }
    }

    func scheduleOpenMenuRebuildIfStillVisible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        closeHostedSubviewMenusBeforeRebuild: Bool = false,
        beforeRebuild: (@MainActor () -> Bool)? = nil)
    {
        let key = ObjectIdentifier(menu)
        if closeHostedSubviewMenusBeforeRebuild {
            self.openMenuRebuildsClosingHostedSubviewMenus.insert(key)
        }
        let shouldCloseHostedSubviewMenus = self.openMenuRebuildsClosingHostedSubviewMenus.contains(key)
        self.openMenuRebuildTokenCounter &+= 1
        let rebuildToken = self.openMenuRebuildTokenCounter
        self.openMenuRebuildTokens[key] = rebuildToken
        self.openMenuRebuildTasks[key]?.cancel()
        self.openMenuRebuildTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            #if DEBUG
            if let override = self._test_openMenuRefreshYieldOverride {
                await override()
            } else {
                await Task.yield()
            }
            #else
            await Task.yield()
            #endif
            guard !Task.isCancelled else { return }
            guard self.openMenuRebuildTokens[key] == rebuildToken else { return }
            defer {
                if self.openMenuRebuildTokens[key] == rebuildToken {
                    self.openMenuRebuildTasks.removeValue(forKey: key)
                    self.openMenuRebuildTokens.removeValue(forKey: key)
                    self.openMenuRebuildsClosingHostedSubviewMenus.remove(key)
                }
            }
            guard self.openMenus[key] != nil else { return }
            guard beforeRebuild?() ?? true else { return }
            if shouldCloseHostedSubviewMenus {
                self.closeHostedSubviewMenusForParentSwitch()
            }
            self.rebuildOpenMenuIfStillVisible(menu, provider: provider)
        }
    }

    private func closeHostedSubviewMenusForParentSwitch() {
        let hostedMenus = self.openMenus.values.filter { self.isHostedSubviewMenu($0) }
        for hostedMenu in hostedMenus {
            hostedMenu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(hostedMenu)
        }
    }
}
