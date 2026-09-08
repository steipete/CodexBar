import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageUpdatedHookTests {
    @Test
    func `repeated usage updates are rate limited`() async throws {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "codexbar-usage-updated-rate-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let event = HookEvent(
            event: .usageUpdated,
            provider: UsageProvider.codex.rawValue,
            timestamp: Date())
        let config = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    event: .usageUpdated,
                    provider: UsageProvider.codex.rawValue,
                    executable: "/bin/sh",
                    arguments: ["-c", #"printf x >> "$1""#, "hook", output.path]),
            ])
        let limiter = HookRateLimiter()

        await HookRunner.dispatch(event: event, config: config, rateLimiter: limiter)
        await HookRunner.dispatch(event: event, config: config, rateLimiter: limiter)

        #expect(try String(contentsOf: output, encoding: .utf8) == "x")
    }

    @Test
    func `published usage update preserves primary and secondary window cadence`() async throws {
        let primaryReset = Date(timeIntervalSince1970: 1_800_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_800_500_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 5 * 60,
                resetsAt: primaryReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: secondaryReset,
                resetDescription: nil),
            updatedAt: Date())

        let payload = try await self.capturePayload(provider: .claude, snapshot: snapshot)

        #expect(payload["window"] == nil)
        #expect(payload["usagePercent"] as? Double == 0.2)
        #expect(payload["windowMinutes"] as? Int == 300)
        #expect(payload["secondaryUsagePercent"] as? Double == 0.5)
        #expect(payload["secondaryWindowMinutes"] as? Int == 10080)
        let formatter = ISO8601DateFormatter()
        let primaryResetString = try #require(payload["resetAt"] as? String)
        let secondaryResetString = try #require(payload["secondaryResetAt"] as? String)
        #expect(formatter.date(from: primaryResetString) == primaryReset)
        #expect(formatter.date(from: secondaryResetString) == secondaryReset)
    }

    @Test
    func `published usage update omits a synthetic primary window`() async throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 7 * 24 * 60,
                resetsAt: Date(timeIntervalSince1970: 1_800_500_000),
                resetDescription: nil),
            updatedAt: Date())

        let payload = try await self.capturePayload(provider: .claude, snapshot: snapshot)

        #expect(payload["usagePercent"] == nil)
        #expect(payload["resetAt"] == nil)
        #expect(payload["windowMinutes"] == nil)
        #expect(payload["secondaryUsagePercent"] as? Double == 0.4)
        #expect(payload["secondaryWindowMinutes"] as? Int == 10080)
    }

    @Test
    func `window cadence is available in the hook environment`() throws {
        let json =
            #"{"event":"usage_updated","provider":"codex","windowMinutes":300,"#
                + #""secondaryUsagePercent":0.4,"secondaryWindowMinutes":10080,"#
                + #""secondaryResetAt":"2026-09-12T12:00:00Z","timestamp":"2026-09-08T12:00:00Z"}"#
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(HookEvent.self, from: data)

        let environment = event.environmentVariables()

        #expect(environment["CODEXBAR_WINDOW_MINUTES"] == "300")
        #expect(environment["CODEXBAR_SECONDARY_USAGE_PERCENT"] == "0.4")
        #expect(environment["CODEXBAR_SECONDARY_WINDOW_MINUTES"] == "10080")
        #expect(environment["CODEXBAR_SECONDARY_RESET_AT"] == "2026-09-12T12:00:00Z")
    }

    @Test
    func `only a successful provider refresh publishes a usage update`() async throws {
        let successOutput = Self.temporaryOutput("success")
        let failureOutput = Self.temporaryOutput("failure")
        defer {
            try? FileManager.default.removeItem(at: successOutput)
            try? FileManager.default.removeItem(at: failureOutput)
        }
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let successStore = self.makeRefreshStore(output: successOutput)
        successStore._test_providerFetchOutcomeOverride = { _ in Self.outcome(snapshot: snapshot) }

        await successStore.refreshProvider(.deepseek, allowDisabled: true)

        let successPayload = try await Self.waitForPayload(at: successOutput)
        #expect(successPayload["event"] as? String == "usage_updated")
        #expect(successPayload["usagePercent"] as? Double == 0.25)

        let failureStore = self.makeRefreshStore(output: failureOutput)
        failureStore._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(CaptureError.providerFailed), attempts: [])
        }

        await failureStore.refreshProvider(.deepseek, allowDisabled: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(!FileManager.default.fileExists(atPath: failureOutput.path))
    }

    @Test
    func `superseded provider refresh cannot publish a usage update`() async throws {
        let output = Self.temporaryOutput("superseded")
        defer { try? FileManager.default.removeItem(at: output) }
        let outcomes = OrderedUsageUpdatedOutcomes()
        let store = self.makeRefreshStore(output: output)
        store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }

        let olderTask = Task { await store.refreshProvider(.deepseek, allowDisabled: true) }
        await outcomes.waitUntilStarted(count: 1)
        let olderGeneration = try #require(
            store.providerRefreshCoordinator.coalescingState(for: UsageProvider.deepseek.instanceID)?.generation)
        let newerTask = Task { await store.refreshProvider(.deepseek, allowDisabled: true) }
        for _ in 0..<100 where store.providerRefreshCoordinator.isCurrent(
            olderGeneration,
            for: UsageProvider.deepseek.instanceID)
        {
            await Task.yield()
        }
        #expect(!store.providerRefreshCoordinator.isCurrent(
            olderGeneration,
            for: UsageProvider.deepseek.instanceID))

        await outcomes.resume(call: 1, outcome: Self.outcome(snapshot: Self.snapshot(usedPercent: 10)))
        await outcomes.waitUntilStarted(count: 2)
        await outcomes.resume(call: 2, outcome: Self.outcome(snapshot: Self.snapshot(usedPercent: 80)))
        await newerTask.value
        await olderTask.value

        let payload = try await Self.waitForPayload(at: output)
        #expect(payload["usagePercent"] as? Double == 0.8)
    }

    private func capturePayload(provider: UsageProvider, snapshot: UsageSnapshot) async throws -> [String: Any] {
        let output = Self.temporaryOutput("payload")
        defer { try? FileManager.default.removeItem(at: output) }
        let hooks = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    event: .usageUpdated,
                    provider: provider.rawValue,
                    executable: "/bin/sh",
                    arguments: ["-c", #"/bin/cat > "$1""#, "hook", output.path]),
            ])
        let settings = testSettingsStore(
            suiteName: "UsageUpdatedHookTests-capture",
            config: CodexBarConfig(
                providers: [ProviderConfig(id: provider.instanceID, enabled: true)],
                hooks: hooks))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["PATH": "/usr/bin:/bin"])

        store.emitUsageUpdatedHook(provider: provider, snapshot: snapshot)

        return try await Self.waitForPayload(at: output)
    }

    private func makeRefreshStore(output: URL) -> UsageStore {
        let hooks = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    event: .usageUpdated,
                    provider: UsageProvider.deepseek.rawValue,
                    executable: "/bin/sh",
                    arguments: ["-c", #"/bin/cat > "$1""#, "hook", output.path]),
            ])
        let settings = testSettingsStore(
            suiteName: "UsageUpdatedHookTests-refresh",
            config: CodexBarConfig(
                providers: [ProviderConfig(id: .deepseek, enabled: true)],
                hooks: hooks))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["PATH": "/usr/bin:/bin"])
    }

    private static func outcome(snapshot: UsageSnapshot) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture.api-token",
                strategyKind: .apiToken)),
            attempts: [])
    }

    private static func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    private static func temporaryOutput(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "codexbar-usage-updated-\(label)-\(UUID().uuidString)")
    }

    private static func waitForPayload(at output: URL) async throws -> [String: Any] {
        for _ in 0..<100 where (try? Data(contentsOf: output).isEmpty) != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw CaptureError.hookDidNotRun
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private enum CaptureError: Error {
        case hookDidNotRun
        case providerFailed
    }
}

private actor OrderedUsageUpdatedOutcomes {
    private var started = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var continuations: [Int: CheckedContinuation<ProviderFetchOutcome, Never>] = [:]

    func next() async -> ProviderFetchOutcome {
        self.started += 1
        let call = self.started
        self.resumeReadyStartWaiters()
        return await withCheckedContinuation { continuation in
            self.continuations[call] = continuation
        }
    }

    func waitUntilStarted(count: Int) async {
        if self.started >= count { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((count: count, continuation: continuation))
        }
    }

    func resume(call: Int, outcome: ProviderFetchOutcome) {
        self.continuations.removeValue(forKey: call)?.resume(returning: outcome)
    }

    private func resumeReadyStartWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.startWaiters {
            if self.started >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.startWaiters = remaining
    }
}
