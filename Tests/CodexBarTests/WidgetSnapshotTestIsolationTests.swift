import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// `WidgetSnapshotStore.load()` opens a file in the real app-group container. On
/// macOS 26 that `open()` can block forever behind app-data (TCC) gating, so a
/// test that reaches `persistWidgetSnapshot` without stubbing the save path hangs
/// the whole suite. These tests pin the gate that keeps container I/O out of tests:
/// persistence runs only for tests that opt in via the in-memory save override or
/// an injected snapshot URL.
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
        let store = Self.makeStore(suite: "no-opt-in")

        store.persistWidgetSnapshot(reason: "test-no-opt-in")

        #expect(store.widgetSnapshotPersistTask == nil)
        #expect(store.lastQueuedWidgetSnapshot == nil)
    }

    @Test
    func `persist with a save override routes the snapshot through the override`() async {
        let store = Self.makeStore(suite: "override")
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "test-override")
        await store.widgetSnapshotPersistTask?.value

        #expect(saved.count == 1)
    }

    @Test
    func `persist with an injected snapshot URL writes to that file`() async {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotTestIsolationTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let store = Self.makeStore(suite: "injected-url", widgetSnapshotURL: snapshotURL)

        store.persistWidgetSnapshot(reason: "test-injected-url")
        await store.widgetSnapshotPersistTask?.value

        #expect(WidgetSnapshotStore.load(from: snapshotURL) != nil)
    }

    private static func makeStore(suite: String, widgetSnapshotURL: URL? = nil) -> UsageStore {
        let settings = testSettingsStore(suiteName: "WidgetSnapshotTestIsolationTests-\(suite)")
        settings.providerDetectionCompleted = true
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: widgetSnapshotURL)
    }
}
