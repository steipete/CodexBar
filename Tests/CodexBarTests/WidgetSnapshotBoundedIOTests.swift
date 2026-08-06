import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct WidgetSnapshotBoundedIOTests {
    @Test
    func `snapshot roundtrip completes through bounded file IO`() throws {
        WidgetSnapshotStore._test_resetBoundedIOState()
        defer { WidgetSnapshotStore._test_resetBoundedIOState() }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let snapshot = Self.snapshot()

        WidgetSnapshotStore.save(snapshot, to: url, timeout: 2.0)
        let loaded = WidgetSnapshotStore.load(from: url, timeout: 2.0)

        #expect(loaded?.entries.isEmpty == true)
        #expect(loaded?.enabledProviders == [.codex])
        #expect(loaded?.usageBarsShowUsed == true)
        #expect(loaded?.generatedAt == snapshot.generatedAt)
    }

    @Test
    func `bounded operation timeout returns nil and trips the circuit breaker`() {
        WidgetSnapshotStore._test_resetBoundedIOState()
        defer { WidgetSnapshotStore._test_resetBoundedIOState() }
        let counter = LockedCounter()

        let result: Int? = WidgetSnapshotStore._test_performBounded(timeout: 0.1) {
            Thread.sleep(forTimeInterval: 1.0)
            return 1
        }
        let afterTimeout: Int? = WidgetSnapshotStore._test_performBounded(timeout: 1.0) {
            counter.increment()
            return 2
        }

        #expect(result == nil)
        #expect(afterTimeout == nil)
        #expect(counter.value == 0)
    }

    @Test
    func `tripped circuit breaker skips later loads saves and operations immediately`() throws {
        WidgetSnapshotStore._test_resetBoundedIOState()
        defer { WidgetSnapshotStore._test_resetBoundedIOState() }
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("existing.json")
        let skippedSaveURL = directory.appendingPathComponent("skipped.json")
        let snapshot = Self.snapshot()
        WidgetSnapshotStore.save(snapshot, to: existingURL, timeout: 2.0)
        let counter = LockedCounter()

        let timedOut: Int? = WidgetSnapshotStore._test_performBounded(timeout: 0.1) {
            Thread.sleep(forTimeInterval: 1.0)
            return 1
        }
        let start = Date()
        let skipped: Int? = WidgetSnapshotStore._test_performBounded(timeout: 1.0) {
            counter.increment()
            return 2
        }
        let loaded = WidgetSnapshotStore.load(from: existingURL, timeout: 1.0)
        WidgetSnapshotStore.save(snapshot, to: skippedSaveURL, timeout: 1.0)
        let elapsed = Date().timeIntervalSince(start)

        #expect(timedOut == nil)
        #expect(skipped == nil)
        #expect(counter.value == 0)
        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: skippedSaveURL.path))
        #expect(elapsed < 0.25)
    }

    @Test
    func `reset seam restores bounded operations`() {
        WidgetSnapshotStore._test_resetBoundedIOState()
        defer { WidgetSnapshotStore._test_resetBoundedIOState() }

        let timedOut: Int? = WidgetSnapshotStore._test_performBounded(timeout: 0.1) {
            Thread.sleep(forTimeInterval: 1.0)
            return 1
        }
        let blocked: Int? = WidgetSnapshotStore._test_performBounded(timeout: 1.0) { 2 }
        WidgetSnapshotStore._test_resetBoundedIOState()
        let restored: Int? = WidgetSnapshotStore._test_performBounded(timeout: 1.0) { 3 }

        #expect(timedOut == nil)
        #expect(blocked == nil)
        #expect(restored == 3)
    }

    private static func snapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            entries: [],
            enabledProviders: [.codex],
            usageBarsShowUsed: true,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotBoundedIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }
}
