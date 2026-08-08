import Foundation
import Testing
@testable import CodexBarCore

/// Kill-mid-save proof for the single-transaction save cycle (refs #2760; PR #2765 review
/// defect D3): SIGKILLing a real subprocess inside `saveCodexCache` — after per-file table
/// writes have been issued but before the cycle's aggregates and metadata — must leave the
/// previous on-disk state fully intact. The old JSON artifact got this from its atomic
/// single-file replace; the SQLite store gets it from one enclosing BEGIN IMMEDIATE/COMMIT.
struct CostUsageStoreCrashSafetyTests {
    @Test
    func `sigkill mid save leaves the previous state fully intact`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.runProbe(mode: "seed", root: root)
        let seeded = CostUsageStoreCrashHarness.seededCache()
        #expect(Self.shape(of: Self.load(root: root)) == Self.shape(of: seeded))

        let termination = try Self.runProbe(mode: "crash-save", root: root, killAfterFiles: 1)
        #expect(termination.reason == .uncaughtSignal)
        #expect(termination.status == SIGKILL)

        // All-or-nothing: not one table may show the interrupted update. A torn save would
        // surface here as updated per-file days against stale global day aggregates, or as
        // the removed file already deleted.
        let after = Self.load(root: root)
        #expect(Self.shape(of: after) == Self.shape(of: seeded))
    }

    @Test
    func `uninterrupted save applies the update fully`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.runProbe(mode: "seed", root: root)
        let termination = try Self.runProbe(mode: "save", root: root)
        #expect(termination.reason == .exit)
        #expect(termination.status == 0)

        let after = Self.load(root: root)
        #expect(Self.shape(of: after) == Self.shape(of: CostUsageStoreCrashHarness.updatedCache()))
    }
}

// MARK: - Helpers

extension CostUsageStoreCrashSafetyTests {
    /// The comparable persisted surface: global day aggregates plus each file's day map.
    private static func shape(of cache: CostUsageCache) -> [String: [String: [String: [Int]]]] {
        var value = ["days": cache.days]
        for (path, usage) in cache.files {
            value[path] = usage.days
        }
        return value
    }

    private static func load(root: URL) -> CostUsageCache {
        CostUsageStoreAccess.read(cacheRoot: root, calendar: CostUsageStoreCrashHarness.fixtureCalendar)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreCrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func runProbe(
        mode: String,
        root: URL,
        killAfterFiles: Int? = nil) throws -> (reason: Process.TerminationReason, status: Int32)
    {
        let process = Process()
        process.executableURL = self.probeExecutableURL
        process.arguments = [mode, root.path] + (killAfterFiles.map { [String($0)] } ?? [])
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationReason == .exit, process.terminationStatus != 0 {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            Issue.record("probe \(mode) exited \(process.terminationStatus): \(message)")
        }
        return (process.terminationReason, process.terminationStatus)
    }

    private static var probeExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CodexBarCostStoreCrashProbe")
    }
}
