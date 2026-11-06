import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemBlinkGatingTests {
    @Test
    func `idle loading state does not repeat a split icon update`() throws {
        let harness = Harness(merged: false)
        let controller = harness.controller
        defer { controller.releaseStatusItemsForTesting() }
        harness.settings.randomBlinkEnabled = false
        harness.settings.debugLogLevel = .verbose
        harness.store.isRefreshing = true
        controller.iconPerfRefreshCycleMetrics = IconPerfRefreshCycleMetrics()

        controller.updateIcons()

        let metrics = try #require(controller.iconPerfRefreshCycleMetrics)
        #expect(controller.animationDriver == nil)
        #expect(metrics.updateIconsCalls == 1)
        #expect(metrics.renderedCalls + metrics.skippedCalls == 1)
    }

    @Test(arguments: [false, true])
    func `brand icons stop blinking and icon updates do not restart it`(merged: Bool) async throws {
        let harness = Harness(merged: merged)
        let controller = harness.controller
        defer { controller.releaseStatusItemsForTesting() }
        controller.updateBlinkingState()
        let task = try #require(controller.blinkTask)
        await harness.clock.waitForSleep()

        harness.settings.menuBarShowsBrandIconWithPercent = true
        controller.updateIcons()
        #expect(controller.blinkTask == nil)
        #expect(harness.settings.randomBlinkEnabled)
        let reads = harness.clock.reads
        harness.clock.wake()
        await task.value
        #expect(harness.clock.reads == reads)

        controller.iconPerfRefreshCycleMetrics = IconPerfRefreshCycleMetrics()
        controller.iconPerfUpdatePassActive = true
        controller.updateBlinkingState()
        #expect(controller.iconPerfRefreshCycleMetrics?.renderedCalls == 0)
        #expect(controller.iconPerfRefreshCycleMetrics?.skippedCalls == 0)
        controller.iconPerfUpdatePassActive = false
        controller.updateIcons()
        controller.handleDebugBlinkNotification()
        #expect(controller.blinkTask == nil)

        harness.settings.menuBarShowsBrandIconWithPercent = false
        controller.updateIcons()
        #expect(controller.blinkTask != nil)
    }

    @Test(arguments: [false, true])
    func `missing brand image resumes legacy critter blinking`(merged: Bool) async throws {
        let harness = Harness(merged: merged)
        let controller = harness.controller
        defer { controller.releaseStatusItemsForTesting() }
        harness.settings.menuBarShowsBrandIconWithPercent = true
        controller.updateIcons()
        #expect(controller.blinkTask == nil)
        #expect(controller.renderedMenuBarLayoutResolution(for: .codex).usesLegacyRendering)

        controller.brandIcon = { _ in nil }
        controller.updateIcons()
        let task = try #require(controller.blinkTask)
        controller.blinkStates[.codex] = StatusItemController.BlinkState(
            nextBlink: harness.clock.now,
            blinkStart: harness.clock.now)
        await harness.clock.waitForSleep()
        #expect(harness.clock.delays.last == .milliseconds(75))
        harness.clock.now.addTimeInterval(0.1)
        harness.clock.wake()
        await harness.clock.waitForSleep()
        #expect((controller.blinkAmounts[.codex] ?? 0) > 0)

        controller.brandIcon = { [image = harness.image] _ in image }
        controller.updateIcons()
        #expect(controller.blinkTask == nil)
        #expect(controller.blinkAmounts.isEmpty)
        harness.clock.wake()
        await task.value
    }

    @Test(arguments: [false, true])
    func `stored layout without a brand image stays static`(merged: Bool) {
        let harness = Harness(merged: merged)
        let controller = harness.controller
        defer { controller.releaseStatusItemsForTesting() }
        harness.settings.menuBarShowsBrandIconWithPercent = true
        harness.settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .providerName]])
        controller.brandIcon = { _ in nil }
        controller.updateIcons()
        #expect(!controller.renderedMenuBarLayoutResolution(for: .codex).usesLegacyRendering)
        #expect(controller.blinkTask == nil)
    }

    @Test
    func `static provider is not redrawn while another provider blinks`() async throws {
        let harness = Harness(merged: false)
        let controller = harness.controller
        defer { controller.releaseStatusItemsForTesting() }
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        harness.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        harness.store._setSnapshotForTesting(harness.snapshot, provider: .claude)
        harness.settings.menuBarShowsBrandIconWithPercent = true
        harness.settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .providerName]]), for: .claude)
        controller.brandIcon = { _ in nil }
        controller.refreshExistingStatusItemsForVisibilityRecovery()
        #expect(controller.isVisible(.claude))
        controller.updateIcons()
        let task = try #require(controller.blinkTask)
        await harness.clock.waitForSleep()
        controller.iconPerfRefreshCycleMetrics = IconPerfRefreshCycleMetrics()
        controller.iconPerfUpdatePassActive = true
        harness.clock.wake()
        await harness.clock.waitForSleep()
        let metrics = try #require(controller.iconPerfRefreshCycleMetrics)
        #expect(metrics.renderedCalls + metrics.skippedCalls == 1)
        controller.iconPerfUpdatePassActive = false
        harness.settings.randomBlinkEnabled = false
        controller.updateBlinkingState()
        harness.clock.wake()
        await task.value
    }

    @MainActor
    private final class Harness {
        let settings = testSettingsStore(
            suiteName: "StatusItemBlinkGatingTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        let clock = Clock()
        let image = NSImage(size: NSSize(width: 18, height: 18))
        let store: UsageStore
        let controller: StatusItemController
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000))

        init(merged: Bool) {
            self.settings.statusChecksEnabled = false
            self.settings.refreshFrequency = .manual
            self.settings.mergeIcons = merged
            self.settings.mergeIconsStacked = false
            self.settings.selectedMenuProvider = .codex
            self.settings.randomBlinkEnabled = false
            self.settings.menuBarShowsBrandIconWithPercent = false
            for provider in UsageProvider.allCases {
                if let metadata = ProviderRegistry.shared.metadata[provider] {
                    self.settings.setProviderEnabled(
                        provider: provider,
                        metadata: metadata,
                        enabled: provider == .codex || (merged && provider == .openrouter))
                }
            }
            let fetcher = UsageFetcher(environment: [:])
            self.store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: self.settings,
                startupBehavior: .testing,
                environmentBase: [:])
            self.store._setSnapshotForTesting(self.snapshot, provider: .codex)
            self.store._setSnapshotForTesting(self.snapshot, provider: .claude)
            self.controller = StatusItemController(
                store: self.store,
                settings: self.settings,
                account: AccountInfo(email: nil, plan: nil),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: testStatusBar())
            self.controller.blinkNow = { [clock] in clock.reads += 1; return clock.now }
            self.controller.blinkSleep = { [clock] in await clock.sleep($0) }
            self.controller.brandIcon = { [image] _ in image }
            self.settings.randomBlinkEnabled = true
            #expect(self.controller.shouldMergeIcons == merged)
        }
    }

    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        var reads = 0
        var delays: [Duration] = []
        private var sleeper: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func sleep(_ duration: Duration) async {
            self.delays.append(duration)
            await withCheckedContinuation { continuation in
                self.sleeper = continuation
                self.observer?.resume()
                self.observer = nil
            }
        }

        func waitForSleep() async {
            guard self.sleeper == nil else { return }
            await withCheckedContinuation { self.observer = $0 }
        }

        func wake() {
            let sleeper = self.sleeper
            self.sleeper = nil
            sleeper?.resume()
        }
    }
}
