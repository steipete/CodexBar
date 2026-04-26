import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct AppDelegateTests {
    @Test
    func `builds status controller after launch`() {
        let appDelegate = AppDelegate()
        var factoryCalls = 0
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AppDelegateTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let account = fetcher.loadAccountInfo()
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)

        // Install a test factory that records invocations without touching NSStatusBar.
        StatusItemController.factory = { _, _, _, _, _, receivedManagedCoordinator, receivedPromotionCoordinator in
            factoryCalls += 1
            #expect(receivedManagedCoordinator === managedCodexAccountCoordinator)
            #expect(receivedPromotionCoordinator === promotionCoordinator)
            return DummyStatusController()
        }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }

        // configure should not eagerly construct the status controller
        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator))
        #expect(factoryCalls == 0)

        // construction happens once after launch
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)

        // idempotent on subsequent calls
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)
    }
}

@MainActor
private final class DummyStatusController: StatusItemControlling {
    func openMenuFromShortcut() {}
}
