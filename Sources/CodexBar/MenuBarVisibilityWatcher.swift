import AppKit
import Foundation

struct StatusItemVisibilitySnapshot: Equatable {
    let isVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasScreen: Bool
    let isOnCurrentScreen: Bool
    let buttonWidth: CGFloat

    init(
        isVisible: Bool,
        hasButton: Bool,
        hasWindow: Bool,
        hasScreen: Bool,
        isOnCurrentScreen: Bool = true,
        buttonWidth: CGFloat)
    {
        self.isVisible = isVisible
        self.hasButton = hasButton
        self.hasWindow = hasWindow
        self.hasScreen = hasScreen
        self.isOnCurrentScreen = isOnCurrentScreen
        self.buttonWidth = buttonWidth
    }
}

extension StatusItemVisibilitySnapshot: CustomStringConvertible {
    var description: String {
        "visible=\(self.isVisible),button=\(self.hasButton),window=\(self.hasWindow),"
            + "screen=\(self.hasScreen),currentScreen=\(self.isOnCurrentScreen),"
            + "width=\(String(format: "%.1f", Double(self.buttonWidth)))"
    }
}

@MainActor
func isStatusItemBlocked(_ item: NSStatusItem) -> Bool {
    MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: MenuBarVisibilityWatcher.visibilitySnapshot(item))
}

enum MenuBarVisibilityWatcher {
    static let guidanceShownKey = "hasShownTahoeAllowListGuidance"
    static let guidanceLastShownAtKey = "tahoeAllowListGuidanceLastShownAt"
    static let guidanceRepeatInterval: TimeInterval = 24 * 60 * 60
    static let startupFreshnessInterval: TimeInterval = 10
    static let startupCheckDelay: TimeInterval = 2
    static let screenChangeCheckDelay: Duration = .milliseconds(750)
    static let screenChangeFollowUpDelay: Duration = .seconds(2)
    static let screenChangeRecoveryRetryLimit = 3
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.MenuBarSettings")!

    @MainActor
    static func visibilitySnapshot(_ item: NSStatusItem) -> StatusItemVisibilitySnapshot {
        let screen = item.button?.window?.screen
        return StatusItemVisibilitySnapshot(
            isVisible: item.isVisible,
            hasButton: item.button != nil,
            hasWindow: item.button?.window != nil,
            hasScreen: screen != nil,
            isOnCurrentScreen: screen.map(self.isCurrentScreen) ?? false,
            buttonWidth: item.button?.frame.size.width ?? 0)
    }

    @MainActor
    private static func isCurrentScreen(_ screen: NSScreen) -> Bool {
        let screenNumber = self.screenNumber(screen)
        return NSScreen.screens.contains { candidate in
            if let screenNumber, let candidateNumber = self.screenNumber(candidate) {
                return candidateNumber == screenNumber
            }
            return candidate === screen
        }
    }

    private static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    static func isBlockedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible else { return false }
        guard snapshot.hasButton else { return true }
        // Menu bar managers can park status-item windows off the current screen while preserving the
        // underlying NSStatusItem. Recreating in that state makes those managers see a new item.
        return !snapshot.hasWindow || snapshot.buttonWidth <= 0
    }

    static func isDisplacedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible, snapshot.hasButton, snapshot.hasWindow, snapshot.buttonWidth > 0 else {
            return false
        }
        return !snapshot.hasScreen || !snapshot.isOnCurrentScreen
    }

    static func hasBlockedVisibleSnapshots(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        let visibleItems = snapshots.filter(\.isVisible)
        guard !visibleItems.isEmpty else { return false }
        return visibleItems.allSatisfy { snapshot in
            self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnyBlockedVisibleSnapshot(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        snapshots.contains { snapshot in
            snapshot.isVisible && self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnyDisplacedVisibleSnapshot(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        snapshots.contains { snapshot in
            self.isDisplacedSnapshot(snapshot: snapshot)
        }
    }

    @MainActor
    static func visibilitySnapshots(_ items: [NSStatusItem]) -> [StatusItemVisibilitySnapshot] {
        items.map { item in
            self.visibilitySnapshot(item)
        }
    }

    @MainActor
    static func hasBlockedVisibleStatusItems(_ items: [NSStatusItem]) -> Bool {
        self.hasBlockedVisibleSnapshots(self.visibilitySnapshots(items))
    }

    static func shouldAttemptStartupRecovery(
        appLaunchedAt: Date,
        now: Date = Date(),
        snapshots: [StatusItemVisibilitySnapshot])
        -> Bool
    {
        guard now.timeIntervalSince(appLaunchedAt) <= self.startupFreshnessInterval else { return false }
        return self.hasAnyBlockedVisibleSnapshot(snapshots)
    }

    static func shouldRefreshScreenChangePlacement(
        previousScreenCount: Int,
        currentScreenCount: Int,
        snapshots: [StatusItemVisibilitySnapshot])
        -> Bool
    {
        guard currentScreenCount < previousScreenCount else { return false }
        return self.hasAnyDisplacedVisibleSnapshot(snapshots)
    }

    static func shouldAttemptScreenChangeRecovery(snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        self.hasAnyBlockedVisibleSnapshot(snapshots)
    }

    static func shouldRetryScreenChangeRecovery(
        attempt: Int,
        snapshots: [StatusItemVisibilitySnapshot])
        -> Bool
    {
        attempt < self.screenChangeRecoveryRetryLimit && self.hasAnyBlockedVisibleSnapshot(snapshots)
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
    func scheduleStartupStatusItemVisibilityCheck(appLaunchedAt: Date = Date()) {
        guard !SettingsStore.isRunningTests else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarVisibilityWatcher.startupCheckDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkStartupStatusItemVisibility(appLaunchedAt: appLaunchedAt)
            }
        }
    }

    private func checkStartupStatusItemVisibility(appLaunchedAt: Date, now: Date = Date()) {
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        guard MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: appLaunchedAt,
            now: now,
            snapshots: snapshots)
        else {
            return
        }

        self.menuLogger.error(
            "Status item failed to materialize; recreating status items",
            metadata: ["snapshots": snapshots.map(\.description).joined(separator: " | ")])
        self.recreateStatusItemsForVisibilityRecovery()

        let recoveredSnapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        guard MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: appLaunchedAt,
            now: now,
            snapshots: recoveredSnapshots)
        else {
            self.menuLogger.info(
                "Status item materialized after recreation",
                metadata: ["snapshots": recoveredSnapshots.map(\.description).joined(separator: " | ")])
            return
        }

        self.menuLogger.error(
            "Status item still failed to materialize after recreation",
            metadata: ["snapshots": recoveredSnapshots.map(\.description).joined(separator: " | ")])
        guard #available(macOS 26.0, *),
              MenuBarVisibilityWatcher.shouldShowGuidance(defaults: self.settings.userDefaults, now: now)
        else {
            return
        }
        MenuBarVisibilityWatcher.presentGuidance(defaults: self.settings.userDefaults, now: now)
    }

    @objc func handleScreenParametersDidChange(_: Notification) {
        let previousScreenCount = max(
            self.pendingScreenChangePreviousCount ?? self.lastKnownScreenCount,
            self.lastKnownScreenCount)
        let currentScreenCount = NSScreen.screens.count
        self.pendingScreenChangePreviousCount = previousScreenCount
        self.lastKnownScreenCount = currentScreenCount
        self.scheduleScreenChangeStatusItemVisibilityCheck(
            previousScreenCount: previousScreenCount,
            currentScreenCount: currentScreenCount)
    }

    private func scheduleScreenChangeStatusItemVisibilityCheck(
        previousScreenCount: Int,
        currentScreenCount: Int)
    {
        guard !SettingsStore.isRunningTests else { return }
        self.screenChangeVisibilityTask?.cancel()
        self.screenChangeVisibilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: MenuBarVisibilityWatcher.screenChangeCheckDelay)
            } catch {
                return
            }
            self?.checkScreenChangeStatusItemVisibility(
                previousScreenCount: previousScreenCount,
                currentScreenCount: currentScreenCount)
        }
    }

    private func checkScreenChangeStatusItemVisibility(previousScreenCount: Int, currentScreenCount: Int) {
        self.pendingScreenChangePreviousCount = nil
        let settledCurrentScreenCount = NSScreen.screens.count
        self.lastKnownScreenCount = settledCurrentScreenCount
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        if MenuBarVisibilityWatcher.shouldAttemptScreenChangeRecovery(snapshots: snapshots) {
            self.menuLogger.error(
                "Display configuration changed; recreating status items",
                metadata: [
                    "previousScreenCount": "\(previousScreenCount)",
                    "currentScreenCount": "\(settledCurrentScreenCount)",
                    "capturedScreenCount": "\(currentScreenCount)",
                    "snapshots": snapshots.map(\.description).joined(separator: " | "),
                ])
            self.recreateStatusItemsForVisibilityRecovery()
            self.schedulePostScreenChangeRecoveryVerification(attempt: 1)
            return
        }

        guard MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: previousScreenCount,
            currentScreenCount: settledCurrentScreenCount,
            snapshots: snapshots)
        else {
            return
        }

        self.menuLogger.info(
            "Display configuration changed; refreshing existing status items",
            metadata: [
                "previousScreenCount": "\(previousScreenCount)",
                "currentScreenCount": "\(settledCurrentScreenCount)",
                "capturedScreenCount": "\(currentScreenCount)",
                "snapshots": snapshots.map(\.description).joined(separator: " | "),
            ])
        self.refreshExistingStatusItemsForVisibilityRecovery()
    }

    private func schedulePostScreenChangeRecoveryVerification(attempt: Int) {
        self.screenChangeVisibilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: MenuBarVisibilityWatcher.screenChangeFollowUpDelay)
            } catch {
                return
            }
            self?.verifyScreenChangeRecoveryIfNeeded(attempt: attempt)
        }
    }

    private func verifyScreenChangeRecoveryIfNeeded(attempt: Int) {
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        guard MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot(snapshots) else {
            self.menuLogger.info(
                "Status item recovered after display-change recovery",
                metadata: ["attempt": "\(attempt)", "snapshots": snapshots.map(\.description).joined(separator: " | ")])
            return
        }

        guard MenuBarVisibilityWatcher.shouldRetryScreenChangeRecovery(attempt: attempt, snapshots: snapshots) else {
            self.menuLogger.error(
                "Status item still blocked after display-change recovery retries",
                metadata: [
                    "attempt": "\(attempt)",
                    "snapshots": snapshots.map(\.description).joined(separator: " | "),
                ])
            guard #available(macOS 26.0, *),
                  MenuBarVisibilityWatcher.shouldShowGuidance(defaults: self.settings.userDefaults)
            else {
                return
            }
            MenuBarVisibilityWatcher.presentGuidance(defaults: self.settings.userDefaults)
            return
        }
        self.menuLogger.error(
            "Status item still blocked after display-change recovery; recreating status items again",
            metadata: [
                "attempt": "\(attempt)",
                "snapshots": snapshots.map(\.description).joined(separator: " | "),
            ])
        self.recreateStatusItemsForVisibilityRecovery()
        self.schedulePostScreenChangeRecoveryVerification(attempt: attempt + 1)
    }

    private var startupVisibilityStatusItems: [NSStatusItem] {
        [self.statusItem] + Array(self.statusItems.values)
    }
}
