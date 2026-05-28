import AppKit
import CodexBarCore
import Foundation
import ObjectiveC

@MainActor
private final class PersistentMenuPrewarmState {
    var task: Task<Void, Never>?
    var scheduledVersion: Int?
    var completedVersion: Int?
}

private enum PersistentMenuPrewarmAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}

extension StatusItemController {
    private var persistentMenuPrewarmState: PersistentMenuPrewarmState {
        if let state = objc_getAssociatedObject(
            self,
            &PersistentMenuPrewarmAssociation.key) as? PersistentMenuPrewarmState
        {
            return state
        }

        let state = PersistentMenuPrewarmState()
        objc_setAssociatedObject(
            self,
            &PersistentMenuPrewarmAssociation.key,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    func startResponsiveMenuSupportIfNeeded() {
        self.startMainRunLoopStallMonitorIfNeeded()
        self.schedulePersistentMenuPrewarm(reason: "startup")
    }

    func schedulePersistentMenuPrewarm(reason: String) {
        guard Self.menuRefreshEnabled else { return }
        guard !SettingsStore.isRunningTests else { return }

        let version = self.menuContentVersion
        let state = self.persistentMenuPrewarmState
        guard state.completedVersion != version else { return }
        if state.scheduledVersion == version, state.task != nil {
            return
        }

        state.task?.cancel()
        state.scheduledVersion = version
        let delay: Duration = reason == "startup" ? .milliseconds(250) : .milliseconds(900)
        state.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let state = self.persistentMenuPrewarmState
            guard state.scheduledVersion == version else { return }
            state.task = nil
            guard !self.hasPreparedForAppShutdown else { return }
            guard self.openMenus.isEmpty else { return }
            guard self.persistentMenusNeedPrewarm(reason: reason) else {
                state.completedVersion = version
                return
            }
            self.prewarmPersistentMenus(reason: reason)
            state.completedVersion = version
        }
    }

    private func persistentMenusNeedPrewarm(reason: String) -> Bool {
        if reason == "startup" {
            return true
        }
        if self.shouldMergeIcons {
            return self.mergedMenu.map { self.menuNeedsRefresh($0) } ?? false
        }

        for menu in self.providerMenus.values where self.menuNeedsRefresh(menu) {
            return true
        }
        return self.fallbackMenu.map { self.menuNeedsRefresh($0) } ?? false
    }

    private func prewarmPersistentMenus(reason: String) {
        guard Self.menuRefreshEnabled else { return }
        guard self.openMenus.isEmpty else { return }

        let startedAt = Date()
        let count: Int = if self.shouldMergeIcons {
            self.prewarmMergedMenu()
        } else {
            self.prewarmSplitProviderMenus()
        }

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        guard count > 0 || elapsedMs >= 16 else { return }
        self.menuLogger.info(
            "persistent menus prewarmed",
            metadata: [
                "elapsedMs": String(format: "%.1f", elapsedMs),
                "menus": "\(count)",
                "reason": reason,
            ])
    }

    private func prewarmMergedMenu() -> Int {
        let menu = self.mergedMenu ?? self.makeMenu()
        self.mergedMenu = menu
        if self.statusItem.menu !== menu {
            self.statusItem.menu = menu
        }
        return self.populateClosedMenuIfNeeded(menu, provider: self.resolvedMenuProvider()) ? 1 : 0
    }

    private func prewarmSplitProviderMenus() -> Int {
        var count = 0
        let fallback = self.fallbackProvider
        for provider in self.settings.orderedProviders() {
            if self.isEnabled(provider) {
                let menu = self.providerMenus[provider] ?? self.makeMenu(for: provider)
                self.providerMenus[provider] = menu
                count += self.populateClosedMenuIfNeeded(menu, provider: provider) ? 1 : 0
            } else if fallback == provider {
                let menu = self.fallbackMenu ?? self.makeMenu(for: nil)
                self.fallbackMenu = menu
                count += self.populateClosedMenuIfNeeded(menu, provider: nil) ? 1 : 0
            }
        }
        return count
    }

    private func populateClosedMenuIfNeeded(_ menu: NSMenu, provider: UsageProvider?) -> Bool {
        guard self.openMenus[ObjectIdentifier(menu)] == nil else { return false }
        guard self.menuNeedsRefresh(menu) else { return false }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
        return true
    }
}
