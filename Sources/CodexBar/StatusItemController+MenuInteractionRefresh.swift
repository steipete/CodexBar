import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let defaultDeferredMenuInteractionRefreshDelay: Duration = .milliseconds(250)
    private static let slowMenuOperationThreshold: TimeInterval = 0.15

    #if DEBUG
    private static var deferredMenuInteractionRefreshDelayForTesting: Duration = .milliseconds(250)

    static func setDeferredMenuInteractionRefreshDelayForTesting(_ delay: Duration) {
        self.deferredMenuInteractionRefreshDelayForTesting = delay
    }

    static func resetDeferredMenuInteractionRefreshDelayForTesting() {
        self.deferredMenuInteractionRefreshDelayForTesting = self.defaultDeferredMenuInteractionRefreshDelay
    }
    #endif

    private static var deferredMenuInteractionRefreshDelay: Duration {
        #if DEBUG
        deferredMenuInteractionRefreshDelayForTesting
        #else
        defaultDeferredMenuInteractionRefreshDelay
        #endif
    }

    func logMenuOperationDurationIfSlow(
        _ operation: String,
        startedAt: CFTimeInterval,
        menu: NSMenu,
        provider: UsageProvider?)
    {
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed >= Self.slowMenuOperationThreshold else { return }
        self.menuLogger.warning(
            "slow menu operation",
            metadata: [
                "operation": operation,
                "durationMs": String(format: "%.1f", elapsed * 1000),
                "items": "\(menu.items.count)",
                "provider": provider?.rawValue ?? "nil",
                "openMenus": "\(self.openMenus.count)",
                "storeRefreshing": self.store.isRefreshing ? "1" : "0",
            ])
    }

    func deferMenuInteractionRefreshIfNeeded() {
        guard !self.store.isRefreshing else { return }
        self.deferredMenuInteractionRefreshPending = true
    }

    func cancelDeferredMenuInteractionRefreshTask() {
        self.deferredMenuInteractionRefreshTask?.cancel()
        self.deferredMenuInteractionRefreshTask = nil
    }

    func scheduleDeferredMenuInteractionRefreshIfNeeded() {
        guard self.openMenus.isEmpty else { return }
        guard self.deferredMenuInteractionRefreshPending else { return }
        guard !self.hasPreparedForAppShutdown else { return }

        self.cancelDeferredMenuInteractionRefreshTask()
        self.deferredMenuInteractionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.deferredMenuInteractionRefreshDelay)
            guard let self, !Task.isCancelled else { return }
            defer { self.deferredMenuInteractionRefreshTask = nil }
            guard self.openMenus.isEmpty else { return }
            guard self.deferredMenuInteractionRefreshPending else { return }
            guard !self.hasPreparedForAppShutdown else { return }
            guard !self.store.isRefreshing else { return }
            self.deferredMenuInteractionRefreshPending = false
            #if DEBUG
            self.onDeferredMenuInteractionRefreshForTesting?()
            #endif
            self.refreshStore(forceTokenUsage: false, refreshOpenMenusWhenComplete: false)
        }
    }
}
