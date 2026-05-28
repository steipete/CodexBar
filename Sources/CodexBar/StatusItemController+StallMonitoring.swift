import CodexBarCore
import Foundation
import ObjectiveC

private enum MainRunLoopStallMonitorAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}

extension StatusItemController {
    var mainRunLoopStallMonitor: MainRunLoopStallMonitor? {
        get {
            objc_getAssociatedObject(
                self,
                &MainRunLoopStallMonitorAssociation.key) as? MainRunLoopStallMonitor
        }
        set {
            objc_setAssociatedObject(
                self,
                &MainRunLoopStallMonitorAssociation.key,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func startMainRunLoopStallMonitorIfNeeded() {
        guard !SettingsStore.isRunningTests else { return }
        guard self.mainRunLoopStallMonitor == nil else { return }

        let monitor = MainRunLoopStallMonitor(logger: self.menuLogger) { [weak self] in
            guard let self else { return [:] }

            var metadata: [String: String] = [
                "menuContentVersion": "\(self.menuContentVersion)",
                "openMenus": "\(self.openMenus.count)",
                "providerSwitcherToken": "\(self.providerSwitcherUpdateToken)",
                "selectedProvider": self.selectedMenuProvider?.rawValue ?? "nil",
                "storeRefreshing": self.store.isRefreshing ? "1" : "0",
            ]
            if let lastMenuProvider = self.lastMenuProvider {
                metadata["lastMenuProvider"] = lastMenuProvider.rawValue
            }
            if let selection = self.lastMergedSwitcherSelection {
                metadata["switcherSelection"] = selection.logValue
            }
            if let lastInteraction = self.lastProviderSwitcherInteractionAt {
                let ageMs = Date().timeIntervalSince(lastInteraction) * 1000
                metadata["lastSwitcherInteractionAgeMs"] = String(format: "%.1f", ageMs)
            }
            return metadata
        }
        self.mainRunLoopStallMonitor = monitor
        monitor.start()
    }
}
