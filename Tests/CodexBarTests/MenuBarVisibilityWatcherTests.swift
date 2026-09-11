import CoreGraphics
import Foundation
import Testing
@testable import CodexBar

struct MenuBarVisibilityWatcherTests {
    @Test(arguments: [
        (CGRect(x: 0, y: -900, width: 1440, height: 900), CGRect(x: 0, y: -22, width: 76, height: 22), true, false),
        (CGRect(x: 0, y: 1080, width: 1440, height: 900), CGRect(x: 0, y: -900, width: 76, height: 22), false, true),
        (CGRect(x: 0, y: 1080, width: 1440, height: 900), CGRect(x: 0, y: -22, width: 76, height: 22), true, true),
        (CGRect(x: 0, y: 1080, width: 1440, height: 900), CGRect(x: 0, y: -450, width: 76, height: 22), false, true),
        (CGRect(x: 0, y: 1080, width: 1440, height: 22), CGRect(x: 0, y: -22, width: 76, height: 22), false, true),
        (CGRect(x: 0, y: -900, width: 1440, height: 900), CGRect(x: 0, y: 1080, width: 76, height: 22), false, true),
        (CGRect(x: -1440, y: 180, width: 1440, height: 900), CGRect(x: -100, y: 0, width: 76, height: 22), false, true),
    ])
    func `window probe aligns secondary screen coordinates before recovery decisions`(
        _ screenFrame: CGRect, _ windowBounds: CGRect, _ blocked: Bool, _ contained: Bool) throws
    {
        let windows = MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"],
            windowInfo: [[
                kCGWindowName as String: "codexbar-merged",
                kCGWindowOwnerName as String: "Control Center",
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: windowBounds.dictionaryRepresentation,
            ]],
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080), screenFrame])
        let window = try #require(windows.first)
        #expect(window.isWithinDisplayBounds == contained)
        #expect(window.isTahoeBlockedProxy == blocked)
        let detached = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 76)
        let launched = Date(timeIntervalSince1970: 1000)
        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launched,
            now: launched.addingTimeInterval(2),
            snapshots: [detached],
            windowSnapshots: windows,
            detectTahoeBlockedStatusItem: true) == blocked)
        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launched,
            now: launched.addingTimeInterval(2),
            snapshots: [detached],
            windowSnapshots: windows,
            detectTahoeBlockedStatusItem: false))
        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launched,
            now: launched.addingTimeInterval(30),
            snapshots: [detached],
            windowSnapshots: windows,
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `window probe rejects malformed rectangles and unmatched names`() {
        let malformed: [[String: Any]] = [
            [:],
            ["X": 0, "Y": 0, "Width": 76],
            ["X": "invalid", "Y": 0, "Width": 76, "Height": 22],
        ]
        var records = malformed.map {
            [kCGWindowName as String: "codexbar-merged", kCGWindowBounds as String: $0] as [String: Any]
        }
        records.append([
            kCGWindowName as String: "other-item",
            kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 76, height: 22).dictionaryRepresentation,
        ])
        #expect(MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"], windowInfo: records, screenFrames: []).isEmpty)
    }

    @Test
    func `does not flag intentionally hidden status item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item without attached window`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item without button`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: false,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item with zero width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows visible item attached to a screen with width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `window probe matches autosave name and reports display bounds`() {
        let snapshots = MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"],
            windowInfo: [[
                kCGWindowName as String: "codexbar-merged",
                kCGWindowOwnerName as String: "Control Center",
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: [
                    "X": 1680,
                    "Y": 0,
                    "Width": 70,
                    "Height": 24,
                ],
            ]],
            screenFrames: [CGRect(x: 0, y: 0, width: 2056, height: 1329)])

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.name == "codexbar-merged")
        #expect(snapshots.first?.ownerName == "Control Center")
        #expect(snapshots.first?.isOnscreen == true)
        #expect(snapshots.first?.isWithinDisplayBounds == true)
    }

    @Test
    func `window probe detects offscreen status item by bounds`() {
        let snapshots = MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"],
            windowInfo: [[
                kCGWindowName as String: "codexbar-merged",
                kCGWindowOwnerName as String: "Control Center",
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: [
                    "X": 2023,
                    "Y": 0,
                    "Width": 71,
                    "Height": 24,
                ],
            ]],
            screenFrames: [CGRect(x: 0, y: 0, width: 2056, height: 1329)])

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isOnscreen == true)
        #expect(snapshots.first?.isWithinDisplayBounds == false)
    }

    @Test
    func `window probe identifies Tahoe Control Center blocked proxy geometry`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `window probe does not classify generic offscreen manager placement as Tahoe proxy`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 2023, y: 0, width: 71, height: 24),
            isOnscreen: true,
            displayBounds: nil)

        #expect(!snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `window probe does not classify stale hidden Control Center record as Tahoe proxy`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: false,
            displayBounds: nil)

        #expect(!snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `allows visible item attached to a detached screen`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `classifies detached live item as displaced but not blocked`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `classifies stale screen live item as displaced but not blocked`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `guidance shows once then repeats after a day`() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarVisibilityWatcherTests"))
        defaults.removePersistentDomain(forName: "MenuBarVisibilityWatcherTests")
        let now = Date(timeIntervalSince1970: 1000)

        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(defaults: defaults, now: now))

        MenuBarVisibilityWatcher.markGuidanceShown(defaults: defaults, now: now)

        #expect(!MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval - 1)))
        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval)))
    }

    @Test
    func `startup recovery triggers for blocked visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [blocked]))
    }

    @Test
    func `startup recovery retries detached Tahoe proxy corroborated by Control Center geometry`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let detachedProxy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 76)
        let blockedWindow = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: detachedProxy))
        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [detachedProxy],
            windowSnapshots: [blockedWindow],
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `startup recovery retries expected hidden Tahoe item with enabled default and no window`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 76)
        let evidence = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: true,
            snapshot: hidden)

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [hidden],
            evidence: [evidence],
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `startup recovery ignores hidden Tahoe item without app and defaults visibility agreement`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 76)
        let intentionallyHidden = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: false,
            visibilityDefault: true,
            snapshot: hidden)
        let disabledByUser = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: false,
            snapshot: hidden)
        let unknownDefault = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: nil,
            snapshot: hidden)

        for evidence in [intentionallyHidden, disabledByUser, unknownDefault] {
            #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
                appLaunchedAt: launchedAt,
                now: launchedAt.addingTimeInterval(2),
                snapshots: [hidden],
                evidence: [evidence],
                detectTahoeBlockedStatusItem: true))
        }
    }

    @Test
    func `startup recovery ignores hidden item when matching window still exists`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 76)
        let evidence = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: true,
            snapshot: hidden)
        let existingWindow = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 1500, y: 0, width: 76, height: 24),
            isOnscreen: true,
            displayBounds: CGRect(x: 0, y: 0, width: 2056, height: 1329))

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [hidden],
            evidence: [evidence],
            windowSnapshots: [existingWindow],
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `startup recovery ignores stale hidden matching window record`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 76)
        let evidence = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: true,
            snapshot: hidden)
        let staleWindow = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 1500, y: 0, width: 76, height: 24),
            isOnscreen: false,
            displayBounds: CGRect(x: 0, y: 0, width: 2056, height: 1329))

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [hidden],
            evidence: [evidence],
            windowSnapshots: [staleWindow],
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `startup recovery keeps hidden no-window detection Tahoe only`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 76)
        let evidence = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged",
            expectsVisibility: true,
            visibilityDefault: true,
            snapshot: hidden)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [hidden],
            evidence: [evidence]))
    }

    @Test
    func `startup recovery ignores detached live item without Tahoe proxy corroboration`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [managed],
            detectTahoeBlockedStatusItem: true))
    }

    @Test
    func `startup recovery ignores live item attached to a stale screen`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [managed]))
    }

    @Test
    func `startup recovery triggers when one split status item is blocked`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy, blocked]))
    }

    @Test
    func `startup recovery ignores stale checks`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(MenuBarVisibilityWatcher.startupFreshnessInterval + 1),
            snapshots: [blocked]))
    }

    @Test
    func `startup recovery ignores healthy visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy]))
    }

    @Test
    func `screen change placement refresh ignores display removal with healthy status item`() {
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 2,
            currentScreenCount: 1,
            snapshots: [healthy]))
    }

    @Test
    func `screen change placement refresh ignores display removal when no status item is visible`() {
        let hidden = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 2,
            currentScreenCount: 1,
            snapshots: [hidden]))
    }

    @Test
    func `screen change recovery triggers for blocked status item without display count change`() {
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptScreenChangeRecovery(snapshots: [blocked]))
    }

    @Test
    func `screen change placement refresh triggers for detached live item after display removal`() {
        let displaced = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 2,
            currentScreenCount: 1,
            snapshots: [displaced]))
    }

    @Test
    func `screen change placement refresh triggers for stale screen live item after display removal`() {
        let displaced = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 2,
            currentScreenCount: 1,
            snapshots: [displaced]))
    }

    @Test
    func `screen change placement refresh ignores healthy item when display count does not shrink`() {
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 1,
            currentScreenCount: 2,
            snapshots: [healthy]))
    }

    @Test
    func `screen change placement refresh triggers for displaced live item when display count is unchanged`() {
        let displaced = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldRefreshScreenChangePlacement(
            previousScreenCount: 2,
            currentScreenCount: 2,
            snapshots: [displaced]))
    }

    @Test
    func `manager parked item with live window is not blocked`() {
        // A menu bar manager parks items off the active screen with the window intact.
        // hasAnyBlockedVisibleSnapshot must return false so verifyScreenChangeRecoveryIfNeeded
        // does not trigger repeated recreation that corrupts Control Center.
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([managed]))
        #expect(MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([managed]))
    }

    @Test
    func `manager parked item with live window on stale screen is not blocked`() {
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([managed]))
        #expect(MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([managed]))
    }

    @Test
    func `item without window is blocked regardless of screen state`() {
        // A missing window cannot be caused by a manager parking the item; it signals
        // a genuine system block and must trigger recovery.
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([blocked]))
        #expect(!MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([blocked]))
    }
}
