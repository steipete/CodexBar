import AdaptiveReplayKit
import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Anchors the fork-only replay harness's four app-side recorder call sites (see
/// `AdaptiveRefreshTraceRecording`): `StatusItemController.menuWillOpen` ->
/// `recordMenuOpen()`, `UsageStore.nextAdaptiveTimerSleepDuration(for:)` -> `recordDecision(...)`,
/// `UsageStore.runRefresh(...)` -> `recordRefreshCompleted()`, and
/// `UsageStore.noteMenuOpened(at:)` -> `recordTimerAdvanced(...)`. Deleting any one of those lines
/// makes exactly one test below fail red — each call site has no other observable effect, so a
/// trace-content assertion is the only way to catch its regression.
///
/// Tracing defaults to off (the same `UserDefaults.standard.bool(forKey:)` gate as
/// `debugDisableKeychainAccess`), so every test explicitly flips
/// `AdaptiveRefreshTraceRecording.defaultsKey` on and points the recorder at a throwaway file via
/// `writerOverrideForTesting`, restoring both in a `defer`. `.serialized` because both are shared,
/// process-global mutable state.
@Suite(.serialized)
@MainActor
struct AdaptiveRefreshTraceRecordingTests {
    private func withTracingEnabled(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-refresh-trace-test-\(UUID().uuidString).jsonl")
        let writer = AdaptiveRefreshTraceWriter(fileURL: url)
        AdaptiveRefreshTraceRecording.writerOverrideForTesting = writer
        UserDefaults.standard.set(true, forKey: AdaptiveRefreshTraceRecording.defaultsKey)
        defer {
            AdaptiveRefreshTraceRecording.writerOverrideForTesting = nil
            UserDefaults.standard.removeObject(forKey: AdaptiveRefreshTraceRecording.defaultsKey)
            try? FileManager.default.removeItem(at: url)
        }
        try await body(url)
    }

    /// Polls the trace file (the writer appends on a private background queue, so a line is not
    /// guaranteed to be visible the instant the call site returns) until `predicate` matches or
    /// `timeout` elapses.
    private func waitForRecords(
        at url: URL,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(20),
        _ predicate: ([AdaptiveRefreshTraceRecord]) -> Bool) async throws -> [AdaptiveRefreshTraceRecord]
    {
        let deadline = ContinuousClock.now + timeout
        while true {
            let records = (try? AdaptiveRefreshTraceParser.parse(contentsOf: url)) ?? []
            if predicate(records) { return records }
            if ContinuousClock.now >= deadline { throw CancellationError() }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(20),
        _ condition: () -> Bool) async throws
    {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                throw CancellationError()
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func makeSettingsStore(suite: String, frequency: RefreshFrequency) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = frequency
        Self.disableAllProviders(settings: settings)
        return settings
    }

    /// Disabling every provider keeps `refresh()` cheap and deterministic: these tests care about
    /// whether a trace line was written, not about provider fetch results.
    private static func disableAllProviders(settings: SettingsStore) {
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            guard let providerMetadata = metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: providerMetadata, enabled: false)
        }
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    @Test
    func `tracing disabled by default writes nothing when a decision tick runs`() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-refresh-trace-test-\(UUID().uuidString).jsonl")
        let writer = AdaptiveRefreshTraceWriter(fileURL: url)
        AdaptiveRefreshTraceRecording.writerOverrideForTesting = writer
        defer {
            AdaptiveRefreshTraceRecording.writerOverrideForTesting = nil
            try? FileManager.default.removeItem(at: url)
        }
        #expect(!AdaptiveRefreshTraceRecording.isEnabled)

        let settings = Self.makeSettingsStore(
            suite: "AdaptiveRefreshTraceRecordingTests-disabled",
            frequency: .adaptive)
        let store = Self.makeUsageStore(settings: settings)
        _ = await UsageStore.nextAdaptiveTimerSleepDuration(for: store)

        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Anchors `UsageStore+AdaptiveRefresh.swift`'s `recordDecision(...)` call inside
    /// `nextAdaptiveTimerSleepDuration(for:)`.
    @Test
    func `enabling tracing records a decision line with the tick's own signals`() async throws {
        try await self.withTracingEnabled { url in
            let settings = Self.makeSettingsStore(
                suite: "AdaptiveRefreshTraceRecordingTests-decision",
                frequency: .adaptive)
            let store = Self.makeUsageStore(settings: settings)
            _ = await UsageStore.nextAdaptiveTimerSleepDuration(for: store)

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .decision } }
            let decision = try #require(records.first { $0.kind == .decision })
            #expect(decision.reason == "longIdle")
            #expect(decision.delaySeconds == 1800)
            #expect(decision.lowPowerModeEnabled != nil)
            #expect(decision.thermalState != nil)
        }
    }

    /// Anchors the shadow-mode `CodingActivityProbe` plumb-through: `recordDecision`'s two optional
    /// activity parameters must land unchanged in the recorded trace line. This calls
    /// `recordDecision` directly with explicit sample values rather than going through
    /// `nextAdaptiveTimerSleepDuration`, so the assertion is independent of whatever the real
    /// `~/.codex` / `~/.claude` directories on the machine running this test happen to contain.
    @Test
    func `recordDecision plumbs the coding-activity probe sample into the trace line`() async throws {
        try await self.withTracingEnabled { url in
            AdaptiveRefreshTraceRecording.recordDecision(
                now: Date(),
                lastMenuOpenAt: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                decision: AdaptiveRefreshPolicy.Decision(delay: .seconds(1800), reason: .longIdle),
                codexActivitySeconds: 42,
                claudeActivitySeconds: 99)

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .decision } }
            let decision = try #require(records.first { $0.kind == .decision })
            #expect(decision.codexActivitySeconds == 42)
            #expect(decision.claudeActivitySeconds == 99)
        }
    }

    /// The default (no probe sample supplied) keeps recording nil activity fields, matching every
    /// existing call site that doesn't pass them.
    @Test
    func `recordDecision without an activity sample records nil activity fields`() async throws {
        try await self.withTracingEnabled { url in
            AdaptiveRefreshTraceRecording.recordDecision(
                now: Date(),
                lastMenuOpenAt: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                decision: AdaptiveRefreshPolicy.Decision(delay: .seconds(1800), reason: .longIdle))

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .decision } }
            let decision = try #require(records.first { $0.kind == .decision })
            #expect(decision.codexActivitySeconds == nil)
            #expect(decision.claudeActivitySeconds == nil)
        }
    }

    /// Anchors `StatusItemController+Menu.swift`'s `recordMenuOpen()` call inside `menuWillOpen`.
    @Test
    func `menuWillOpen records a menuOpen line`() async throws {
        try await self.withTracingEnabled { url in
            let settings = Self.makeSettingsStore(
                suite: "AdaptiveRefreshTraceRecordingTests-menuOpen",
                frequency: .manual)
            let store = Self.makeUsageStore(settings: settings)
            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: UsageFetcher().loadAccountInfo(),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: .system)
            defer { controller.releaseStatusItemsForTesting() }

            let menu = controller.makeMenu()
            controller.menuWillOpen(menu)

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .menuOpen } }
            #expect(records.contains { $0.kind == .menuOpen })
        }
    }

    /// Anchors `UsageStore.swift`'s `recordRefreshCompleted()` call inside `runRefresh(...)`.
    @Test
    func `a completed refresh records a refreshCompleted line`() async throws {
        try await self.withTracingEnabled { url in
            let settings = Self.makeSettingsStore(
                suite: "AdaptiveRefreshTraceRecordingTests-refreshCompleted",
                frequency: .manual)
            let store = Self.makeUsageStore(settings: settings)

            await store.refresh()

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .refreshCompleted } }
            #expect(records.contains { $0.kind == .refreshCompleted })
        }
    }

    /// Anchors `UsageStore.swift`'s `recordTimerAdvanced(...)` call inside `noteMenuOpened(at:)` —
    /// the one new call site this task's trace schema exists for. Follows the exact
    /// `restartTimerWithSleepOverrideForTesting` / `waitUntil` setup `AdaptiveRefreshTimerTests`'
    /// `menu open advances a long idle timer during refresh without postponing an earlier tick`
    /// uses to make the real advance deterministic, then asserts on the recorded trace line instead
    /// of (only) the in-memory `adaptiveRefreshScheduledAt`.
    @Test
    func `noteMenuOpened records a timerAdvanced line only when the schedule actually moves earlier`() async throws {
        try await self.withTracingEnabled { url in
            let settings = Self.makeSettingsStore(
                suite: "AdaptiveRefreshTraceRecordingTests-advance",
                frequency: .adaptive)
            let store = Self.makeUsageStore(settings: settings)
            store.restartTimerWithSleepOverrideForTesting(.seconds(10))
            try await Self.waitUntil { store.adaptiveRefreshScheduledAt != nil }
            let longIdleSchedule = try #require(store.adaptiveRefreshScheduledAt)

            store.noteMenuOpened()
            try await Self.waitUntil {
                guard let scheduledAt = store.adaptiveRefreshScheduledAt else { return false }
                return scheduledAt < longIdleSchedule
            }
            let interactionSchedule = try #require(store.adaptiveRefreshScheduledAt)

            let records = try await self.waitForRecords(at: url) { $0.contains { $0.kind == .timerAdvanced } }
            let advancedRecords = records.filter { $0.kind == .timerAdvanced }
            #expect(advancedRecords.count == 1)
            let advanced = try #require(advancedRecords.first)
            // ISO 8601 encoding (AdaptiveRefreshTraceWriter's wire format) is whole-second
            // resolution, so compare with a sub-second tolerance rather than exact equality.
            let recordedPreviousScheduledAt = try #require(advanced.previousScheduledAt)
            let recordedCandidateScheduledAt = try #require(advanced.candidateScheduledAt)
            #expect(abs(recordedPreviousScheduledAt.timeIntervalSince(longIdleSchedule)) < 1)
            #expect(abs(recordedCandidateScheduledAt.timeIntervalSince(interactionSchedule)) < 1)
            #expect(advanced.reason == "recentInteraction")

            // A second, near-immediate call cannot produce a strictly earlier candidate than the
            // one just scheduled (mirrors AdaptiveRefreshTimerTests' own assertion that
            // `adaptiveRefreshScheduledAt` is unchanged for this exact scenario), so no second
            // timerAdvanced line should appear.
            store.noteMenuOpened(at: Date().addingTimeInterval(30))
            try await Task.sleep(for: .milliseconds(300))
            let finalRecords = try AdaptiveRefreshTraceParser.parse(contentsOf: url)
            #expect(finalRecords.count(where: { $0.kind == .timerAdvanced }) == 1)
        }
    }
}
