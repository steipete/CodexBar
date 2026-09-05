import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// `WidgetSnapshotStore.load()` opens a file in the real app-group container. On
/// macOS 26 that `open()` can block forever behind app-data (TCC) gating, so a
/// test that reaches `persistWidgetSnapshot` without stubbing the save path hangs
/// the whole suite. These tests pin the gate that keeps container I/O out of tests:
/// persistence runs only for tests that opt in via the in-memory save override or
/// an injected snapshot URL. Neither opt-in permits WidgetKit reloads.
@MainActor
struct WidgetSnapshotTestIsolationTests {
    @Test
    func `persistence gate only opens for tests that opt in via override or injected URL`() {
        #expect(!UsageStore.shouldPersistWidgetSnapshot(
            isRunningTests: true, hasSaveOverride: false, hasInjectedSnapshotURL: false))
        #expect(UsageStore.shouldPersistWidgetSnapshot(
            isRunningTests: true, hasSaveOverride: true, hasInjectedSnapshotURL: false))
        #expect(UsageStore.shouldPersistWidgetSnapshot(
            isRunningTests: true, hasSaveOverride: false, hasInjectedSnapshotURL: true))
        #expect(UsageStore.shouldPersistWidgetSnapshot(
            isRunningTests: false, hasSaveOverride: false, hasInjectedSnapshotURL: false))
    }

    @Test
    func `persist without any opt-in queues no widget snapshot work`() {
        var reloadCount = 0
        let store = Self.makeStore(suite: "no-opt-in", reloadTimelines: { reloadCount += 1 })

        store.persistWidgetSnapshot(reason: "test-no-opt-in")

        #expect(store.widgetSnapshotPersistTask == nil)
        #expect(store.lastQueuedWidgetSnapshot == nil)
        #expect(reloadCount == 0)
    }

    @Test(arguments: [false, true])
    func `persist with a save override stays in memory without reloading`(injectURL: Bool) async {
        let snapshotURL = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        var reloadCount = 0
        let store = Self.makeStore(
            suite: "override",
            widgetSnapshotURL: injectURL ? snapshotURL : nil,
            reloadTimelines: { reloadCount += 1 })
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "test-override")
        await store.widgetSnapshotPersistTask?.value

        #expect(saved.count == 1)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(reloadCount == 0)
    }

    @Test
    func `persist with an injected snapshot URL writes to that file without reloading`() async {
        let snapshotURL = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        var reloadCount = 0
        let store = Self.makeStore(
            suite: "injected-url",
            widgetSnapshotURL: snapshotURL,
            reloadTimelines: { reloadCount += 1 })

        store.persistWidgetSnapshot(reason: "test-injected-url")
        await store.widgetSnapshotPersistTask?.value

        #expect(WidgetSnapshotStore.load(from: snapshotURL) != nil)
        #expect(reloadCount == 0)
    }

    @Test(arguments: [true, false])
    func `file save reload boundary respects test mode and finishes saving before reload`(
        isRunningTests: Bool) async throws
    {
        // Only the helper's decision is varied; process-wide test isolation stays enabled.
        try #require(SettingsStore.isRunningTests)
        let snapshotURL = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = WidgetSnapshot(
            entries: [],
            enabledProviders: [.codex],
            usageBarsShowUsed: true,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var reloadCount = 0
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

        await UsageStore.saveWidgetSnapshot(
            snapshot,
            to: snapshotURL,
            isRunningTests: isRunningTests,
            reloadTimelines: {
                reloadCount += 1
                #expect(WidgetSnapshotStore.load(from: snapshotURL)?.generatedAt == snapshot.generatedAt)
            })

        let saved = try #require(WidgetSnapshotStore.load(from: snapshotURL))
        #expect(saved.generatedAt == snapshot.generatedAt)
        #expect(saved.enabledProviders == snapshot.enabledProviders)
        #expect(saved.usageBarsShowUsed == snapshot.usageBarsShowUsed)
        #expect(reloadCount == (isRunningTests ? 0 : 1))
        #expect(SettingsStore.isRunningTests)
    }

    private static func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotTestIsolationTests-\(UUID().uuidString).json")
    }

    private static func makeStore(
        suite: String,
        widgetSnapshotURL: URL? = nil,
        reloadTimelines: @escaping @MainActor () -> Void) -> UsageStore
    {
        let settings = testSettingsStore(suiteName: "WidgetSnapshotTestIsolationTests-\(suite)")
        settings.providerDetectionCompleted = true
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: widgetSnapshotURL,
            widgetTimelineReloader: reloadTimelines)
    }
}
