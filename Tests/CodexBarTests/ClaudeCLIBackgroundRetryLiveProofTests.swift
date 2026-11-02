import Foundation
import Testing
@testable import CodexBarCore

/// Drives the installed owner CLI through the app's background Auto gate with Keychain access disabled.
/// A launcher runs the real `claude`; while the "failing" flag is set it passes an unknown option, so the CLI
/// itself exits with an error instead of rendering usage. The availability and spawn-throttle clocks are
/// advanced instead of waiting out the real retry delay.
@Suite(.serialized)
struct ClaudeCLIBackgroundRetryLiveProofTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_CLAUDE_BACKGROUND_RETRY_PROOF"] == "1"
    }

    @Test
    func `live owner CLI failure recovers in the background after the retry delay`() async throws {
        guard Self.isEnabled else { return }
        let live = try LiveCLI()
        defer { live.finish() }
        let retryDelay = ClaudeCLIBackgroundAvailability.initialBackgroundRetryDelay

        await live.withGates {
            #expect(await live.isAvailableInBackground())
            live.setFailing(true)
            let failed = await live.fetch("background fetch")
            #expect(failed.failed && !failed.authenticationFailed)
            live.setFailing(false)

            #expect(await !live.isAvailableInBackground())
            live.advance(by: retryDelay - 1)
            #expect(await !live.isAvailableInBackground())
            live.advance(by: 1)
            #expect(await live.isAvailableInBackground())

            let recovered = await live.fetch("background fetch")
            #expect(recovered.succeeded)
        }
    }
}

private final class LiveCLI: @unchecked Sendable {
    struct Outcome {
        let succeeded: Bool
        let authenticationFailed: Bool

        var failed: Bool {
            !self.succeeded
        }
    }

    private let root: URL
    private let context: ProviderFetchContext
    private let strategy = ClaudeCLIFetchStrategy(
        useWebExtras: false,
        includePrepaidBalance: false,
        manualCookieHeader: nil,
        browserDetection: BrowserDetection(cacheTTL: 0),
        hasWebFallback: false)
    private let lock = NSLock()
    private let start = Date()
    private var offset: TimeInterval = 0

    init() throws {
        let binary = try #require(TTYCommandRunner.which("claude"))
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-live-retry-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)

        // Every attempt, including the probe's own relaunches, runs the real owner CLI through this launcher,
        // so all attempts share one profile marker. A flag file rather than an environment variable selects
        // the mode, so it holds for every child the probe starts.
        let launcher = self.root.appendingPathComponent("claude")
        try """
        #!/bin/sh
        dir='\(self.root.path)'
        if [ -f "$dir/failing" ]; then
          echo "$(date +%T) launch claude with an unknown option" >> "$dir/launcher.log"
          exec '\(binary)' --codexbar-live-proof-unknown-option "$@"
        fi
        echo "$(date +%T) launch claude" >> "$dir/launcher.log"
        exec '\(binary)' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CLI_PATH"] = launcher.path
        environment[KeychainAccessGate.disableAccessEnvironmentKey] = "1"
        #expect(ClaudeCLIBackgroundAvailability.captureMarker(binary: launcher.path, environment: environment) != nil)
        self.context = Self.makeContext(environment)
    }

    func finish() {
        let launches = (try? String(contentsOf: self.root.appendingPathComponent("launcher.log"), encoding: .utf8))
        for line in (launches ?? "").split(separator: "\n") {
            print("[retry-proof]   launcher \(line)")
        }
        try? FileManager.default.removeItem(at: self.root)
    }

    func withGates(operation: () async -> Void) async {
        let now: @Sendable () -> Date = { self.now() }
        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
                await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(now) {
                    await ClaudeCLIBackgroundAvailability.withNowOverrideForTesting(now) {
                        await KeychainAccessGate.withTaskOverrideForTesting(true) {
                            await operation()
                        }
                    }
                }
            }
        }
    }

    func setFailing(_ failing: Bool) {
        let flag = self.root.appendingPathComponent("failing")
        if failing {
            FileManager.default.createFile(atPath: flag.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
        self.log(failing ? "CLI launches now fail" : "CLI launches work again")
    }

    func advance(by interval: TimeInterval) {
        self.lock.withLock { self.offset += interval }
        self.log("clock advanced \(Int(interval))s")
    }

    func isAvailableInBackground() async -> Bool {
        let available = await ProviderInteractionContext.$current.withValue(.background) {
            await self.strategy.isAvailable(self.context)
        }
        self.log("background Auto may launch the CLI: \(available)")
        return available
    }

    func fetch(_ label: String) async -> Outcome {
        let started = Date()
        do {
            let result = try await ProviderInteractionContext.$current.withValue(.background) {
                try await self.strategy.fetch(self.context)
            }
            let hasSession = result.usage.scoped(to: .claude).primary != nil
            self.log("\(label): succeeded, session window present: \(hasSession)", since: started)
            return Outcome(succeeded: true, authenticationFailed: false)
        } catch {
            let isAuthentication = ClaudeUsageFetcher.isCLIAuthenticationError(error)
            self.log(
                "\(label): failed, authentication: \(isAuthentication), error: \(String(describing: error))",
                since: started)
            return Outcome(succeeded: false, authenticationFailed: isAuthentication)
        }
    }

    private func now() -> Date {
        self.lock.withLock { Date().addingTimeInterval(self.offset) }
    }

    private func log(_ message: String, since started: Date? = nil) {
        let elapsed = Int(self.now().timeIntervalSince(self.start))
        let duration = started.map { String(format: " (%.1fs)", Date().timeIntervalSince($0)) } ?? ""
        print("[retry-proof] t+\(elapsed)s \(message)\(duration)")
    }

    private static func makeContext(_ environment: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: environment),
            browserDetection: browserDetection)
    }
}
