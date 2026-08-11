import Foundation
import Testing
@testable import CodexBarCore

/// Launch-crash proof for the store's synchronous bridges, and the regression guard the
/// macOS 26-only fix in #2803 could not provide.
///
/// `CostUsageStore` runs on a custom `DispatchQueue`-backed `SerialExecutor`, and the queue
/// hop in `sharedExecutor.sync` is what actually establishes isolation. Asking the
/// concurrency runtime to re-confirm that fact is what kept trapping: a binary linked
/// against a pre-Swift-6 SDK selects the runtime's legacy executor check, and that path
/// answers "not isolated" for a custom `SerialExecutor` without ever consulting
/// `checkIsolated()`. Released `CodexBar.app` is exactly that binary — it carries
/// `LC_BUILD_VERSION sdk 14.0` — so every launch died with "Incorrect actor executor
/// assumption". macOS 26 escaped it only because that runtime asks
/// `isIsolatingCurrentContext()` first, which is why the trap outlived #2803 on macOS 15.
///
/// This has to be a subprocess. The mode is resolved once per process from the *main
/// executable*, and `swift test` runs under Apple's `xctest`, which always selects the
/// modern path — so an in-process test passes whether or not the bug is present. Pinning the
/// mode in a child process is what makes the failure observable from CI on any host OS.
struct CostUsageStoreExecutorIsolationTests {
    /// Forces the executor-check mode that `CodexBar.app`'s own SDK version selects.
    private static let legacyExecutorMode = "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE"

    @Test
    func `read bridge survives the legacy executor check`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.runProbe(mode: "seed", root: root)
        let result = try Self.runProbe(mode: "load", root: root)

        // Before the fix this died with SIGTRAP on the `assumeIsolated` in syncLoadCodexCache.
        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }

    @Test
    func `write bridge survives the legacy executor check`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try Self.runProbe(mode: "seed", root: root)

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(CostUsageStoreCrashHarness.load(cacheRoot: root) == 3)
    }
}

// MARK: - Helpers

extension CostUsageStoreExecutorIsolationTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func runProbe(
        mode: String,
        root: URL) throws -> (reason: Process.TerminationReason, status: Int32, standardOutput: String)
    {
        let process = Process()
        process.executableURL = self.probeExecutableURL
        process.arguments = [mode, root.path]
        process.environment = ProcessInfo.processInfo.environment
            .merging([Self.legacyExecutorMode: "legacy"]) { _, forced in forced }
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            Issue.record("""
            probe \(mode) terminated \(process.terminationReason) \(process.terminationStatus): \
            \(String(data: errorData, encoding: .utf8) ?? "")
            """)
        }
        return (
            process.terminationReason,
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "")
    }

    private static var probeExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CodexBarCostStoreCrashProbe")
    }
}
