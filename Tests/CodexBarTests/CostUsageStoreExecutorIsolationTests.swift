import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Subprocess proof for the synchronous read/write bridges under the legacy executor check.
/// The test control suppresses macOS 26's current-context answer so the legacy path is exercised.
struct CostUsageStoreExecutorIsolationTests {
    private static let legacyExecutorMode = "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE"
    private static let probeTimeout: DispatchTimeInterval = .seconds(15)

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
        process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCostStoreCrashProbe")
        process.arguments = [CostUsageStoreExecutorTestControl.suppressCurrentContextArgument, mode, root.path]
        process.environment = ProcessInfo.processInfo.environment
            .merging([Self.legacyExecutorMode: "legacy"]) { _, forced in forced }
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + Self.probeTimeout) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + .seconds(2))
            }
            throw ProbeError.timedOut(mode)
        }
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

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

    private enum ProbeError: Error {
        case timedOut(String)
    }
}
