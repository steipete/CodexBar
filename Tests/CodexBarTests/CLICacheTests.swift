import Commander
import Dispatch
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLICacheTests {
    @Test
    func `cache clear parses cookies provider flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._cacheSignatureForTesting())
        let parsed = try parser.parse(arguments: ["--cookies", "--provider", "claude", "--json"])

        #expect(parsed.flags.contains("cookies"))
        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(parsed.options["provider"] == ["claude"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `provider scope is rejected for cost clearing`() {
        #expect(CodexBarCLI.cacheClearProviderScopeError(rawProvider: nil, clearCost: true) == nil)
        #expect(CodexBarCLI.cacheClearProviderScopeError(rawProvider: "claude", clearCost: false) == nil)
        #expect(CodexBarCLI.cacheClearProviderScopeError(rawProvider: "claude", clearCost: true)?
            .contains("--provider only scopes cookie caches") == true)
    }

    @Test
    func `cache help documents provider as cookie scoped`() {
        let help = CodexBarCLI.cacheHelp(version: "0.0.0")

        #expect(help.contains("--provider with --cookies"))
        #expect(help.contains("codexbar cache clear --cookies --provider claude"))
    }

    @Test
    func `cost clear waits for the collector interprocess lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-cost-clear-lock-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: cacheDirectory.appendingPathComponent("usage.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let collector = Task.detached {
            try await CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                _ = await Self.waitForSignal(releaseLock, timeout: .distantFuture)
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

        let clear = Task.detached {
            clearStarted.signal()
            let result = CostUsageCacheLocations.clearAllCostUsageCaches(
                in: [cacheDirectory],
                stateRoot: root,
                fileManager: .default)
            clearFinished.signal()
            return result
        }
        #expect(await Self.waitForSignal(clearStarted, timeout: .now() + 1))
        #expect(!Self.waitForSignalSync(clearFinished, timeout: .now() + .milliseconds(50)))

        releaseLock.signal()
        try await collector.value
        let result = await clear.value
        #expect(result == CostUsageCacheClearResult(cleared: 1, errorDescription: nil))
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }

    private static func waitForSignalSync(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) -> Bool
    {
        semaphore.wait(timeout: timeout) == .success
    }
}
