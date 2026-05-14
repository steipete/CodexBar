import AppKit
import Foundation

struct StatusItemVisibilitySnapshot: Equatable {
    let isVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasScreen: Bool
    let buttonWidth: CGFloat
}

@MainActor
func isStatusItemBlocked(_ item: NSStatusItem) -> Bool {
    MenuBarVisibilityWatcher.isBlockedSnapshot(
        snapshot: StatusItemVisibilitySnapshot(
            isVisible: item.isVisible,
            hasButton: item.button != nil,
            hasWindow: item.button?.window != nil,
            hasScreen: item.button?.window?.screen != nil,
            buttonWidth: item.button?.frame.size.width ?? 0))
}

enum MenuBarVisibilityWatcher {
    static let guidanceShownKey = "hasShownTahoeAllowListGuidance"
    static let guidanceLastShownAtKey = "tahoeAllowListGuidanceLastShownAt"
    static let guidanceRepeatInterval: TimeInterval = 24 * 60 * 60
    static let startupFreshnessInterval: TimeInterval = 10
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.MenuBarSettings")!

    static func isBlockedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible else { return false }
        guard snapshot.hasButton else { return true }
        return !snapshot.hasWindow || !snapshot.hasScreen || snapshot.buttonWidth <= 0
    }

    @MainActor
    static func hasBlockedVisibleStatusItems(_ items: [NSStatusItem]) -> Bool {
        let visibleItems = items.filter(\.isVisible)
        guard !visibleItems.isEmpty else { return false }
        return visibleItems.allSatisfy { item in
            isStatusItemBlocked(item)
        }
    }

    static func shouldShowGuidance(defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: self.guidanceShownKey) else { return true }
        let lastShownAt = defaults.double(forKey: self.guidanceLastShownAtKey)
        guard lastShownAt > 0 else { return false }
        return now.timeIntervalSince1970 - lastShownAt >= self.guidanceRepeatInterval
    }

    static func markGuidanceShown(defaults: UserDefaults, now: Date = Date()) {
        defaults.set(true, forKey: self.guidanceShownKey)
        defaults.set(now.timeIntervalSince1970, forKey: self.guidanceLastShownAtKey)
    }

    @MainActor
    static func presentGuidance(
        defaults: UserDefaults,
        now: Date = Date(),
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) })
    {
        self.markGuidanceShown(defaults: defaults, now: now)

        let alert = NSAlert()
        alert.messageText = L("CodexBar can't show its menu bar icon")
        alert.informativeText = L(
            "macOS Tahoe can block menu bar apps in System Settings → Menu Bar → Allow in the Menu Bar. "
                + "CodexBar is running, but macOS may be hiding its icon. Open Menu Bar settings and turn CodexBar on.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Menu Bar Settings"))
        alert.addButton(withTitle: L("Dismiss"))

        if alert.runModal() == .alertFirstButtonReturn {
            openURL(self.settingsURL)
        }
    }
}

extension StatusItemController {
    func scheduleTahoeAllowListVisibilityCheck(appLaunchedAt: Date = Date()) {
        guard !SettingsStore.isRunningTests else { return }
        if #available(macOS 26.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.checkTahoeAllowListVisibility(appLaunchedAt: appLaunchedAt)
                }
            }
        }
    }

    private func checkTahoeAllowListVisibility(appLaunchedAt: Date, now: Date = Date()) {
        guard now.timeIntervalSince(appLaunchedAt) <= MenuBarVisibilityWatcher.startupFreshnessInterval else {
            return
        }
        guard MenuBarVisibilityWatcher.hasBlockedVisibleStatusItems(self.tahoeAllowListStatusItems) else {
            return
        }

        self.menuLogger.error("Status item failed to materialize — likely blocked by Tahoe Allow in Menu Bar panel")
        guard MenuBarVisibilityWatcher.shouldShowGuidance(defaults: self.settings.userDefaults, now: now) else {
            return
        }
        MenuBarVisibilityWatcher.presentGuidance(defaults: self.settings.userDefaults, now: now)
    }

    private var tahoeAllowListStatusItems: [NSStatusItem] {
        [self.statusItem] + Array(self.statusItems.values)
    }
}
