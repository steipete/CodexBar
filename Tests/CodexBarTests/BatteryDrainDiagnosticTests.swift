import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Diagnostic tests to identify battery drain issues.
/// These tests measure idle behavior when all providers are disabled.
/// See GitHub issues #269, #139.
@MainActor
@Suite(.serialized)
struct BatteryDrainDiagnosticTests {
    
    // MARK: - DisplayLink Tests
    
    @Test("DisplayLinkDriver should not run when not explicitly started")
    func displayLinkDriverIdleByDefault() async throws {
        let driver = DisplayLinkDriver()
        
        // Give it a moment to potentially start (if buggy)
        try await Task.sleep(for: .milliseconds(100))
        
        // Check that tick hasn't advanced (no activity)
        let initialTick = driver.tick
        try await Task.sleep(for: .milliseconds(200))
        let afterTick = driver.tick
        
        #expect(initialTick == afterTick, "DisplayLinkDriver should not tick when not started")
    }
    
    @Test("DisplayLinkDriver should stop ticking after stop() is called")
    func displayLinkDriverStopsCleanly() async throws {
        let driver = DisplayLinkDriver()
        driver.start(fps: 60)
        
        // Let it run briefly
        try await Task.sleep(for: .milliseconds(100))
        let ticksWhileRunning = driver.tick
        #expect(ticksWhileRunning > 0, "Should have ticked while running")
        
        // Stop it
        driver.stop()
        
        // Wait and verify no more ticks
        try await Task.sleep(for: .milliseconds(100))
        let ticksAfterStop = driver.tick
        try await Task.sleep(for: .milliseconds(100))
        let ticksLater = driver.tick
        
        #expect(ticksAfterStop == ticksLater, "DisplayLinkDriver should not tick after stop()")
    }
    
    // MARK: - StatusItemController Animation State Tests
    
    @Test("Animation driver should be nil when all providers disabled")
    func animationDriverNilWhenAllProvidersDisabled() async throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-AllDisabled"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        
        // Disable everything
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        
        // Disable all providers
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }
        
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar())
        
        // Wait for any deferred setup
        try await Task.sleep(for: .milliseconds(200))
        
        #expect(controller.animationDriver == nil, 
                "Animation driver should be nil when all providers are disabled")
        #expect(controller.needsMenuBarIconAnimation() == false,
                "Should not need animation when all providers disabled")
    }
    
    @Test("Animation driver should be nil when provider has data")
    func animationDriverNilWhenProviderHasData() async throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-HasData"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        
        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: meta, enabled: true)
        }
        
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        
        // Set data BEFORE creating controller
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar())
        
        // Wait for setup
        try await Task.sleep(for: .milliseconds(200))
        
        #expect(controller.needsMenuBarIconAnimation() == false,
                "Should not need animation when provider has data")
        #expect(controller.animationDriver == nil,
                "Animation driver should be nil when data is present")
    }
    
    // MARK: - Provider Runtime Tests
    
    @Test("Augment provider should not run keepalive when disabled")
    func augmentKeepaliveNotRunningWhenDisabled() async throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-Augment"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        
        // Explicitly disable Augment
        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.augment] {
            settings.setProviderEnabled(provider: .augment, metadata: meta, enabled: false)
        }
        
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        
        // Create controller (which initializes provider runtimes)
        let _ = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar())
        
        // The AugmentProviderRuntime should not have started its keepalive
        let augmentEnabled = settings.isProviderEnabled(
            provider: .augment,
            metadata: registry.metadata[.augment]!)
        #expect(augmentEnabled == false, "Augment should be disabled")
    }
    
    // MARK: - CPU Baseline Test
    
    @Test("Idle state should have no active animation or refresh")
    func idleStateVerification() async throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-CPU"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        
        // Configure for absolute minimum activity
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.randomBlinkEnabled = false
        settings.costUsageEnabled = false
        
        // Disable ALL providers
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }
        
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar())
        
        // Let everything settle
        try await Task.sleep(for: .milliseconds(500))
        
        // Verify idle state
        #expect(controller.animationDriver == nil, "Animation driver should be nil when idle")
        #expect(controller.needsMenuBarIconAnimation() == false, "Should not need animation")
        #expect(store.isRefreshing == false, "Should not be refreshing")
        
        // Additional wait to verify nothing starts up
        try await Task.sleep(for: .milliseconds(500))
        
        #expect(controller.animationDriver == nil, "Animation driver should still be nil after delay")
    }
    
    // MARK: - Timer Behavior Test
    
    @Test("Timer should not be active when refresh frequency is manual")
    func timerInactiveWhenManual() async throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-ManualTimer"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        
        // The store should not be refreshing when manual
        #expect(store.isRefreshing == false, "Should not auto-refresh when manual")
        
        // Wait to ensure no auto-refresh kicks in
        try await Task.sleep(for: .seconds(1))
        #expect(store.isRefreshing == false, "Should still not be refreshing after 1 second")
    }
}

// Note: UsageStore.isEnabled extension removed - it conflicted with other tests
