import Foundation
import Testing
@testable import CodexBarCore

private enum DoubaoProviderTestError: Error {
    case signedFailed
    case arkShouldNotRun
}

private struct DoubaoProviderTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw DoubaoProviderTestError.signedFailed
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}

struct DoubaoProviderTests {
    @Test
    func `usage snapshot exposes request usage window`() {
        let resetDate = Date(timeIntervalSince1970: 1_742_771_200)
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 80,
            limitRequests: 100,
            resetTime: resetDate,
            updatedAt: resetDate,
            apiKeyValid: true)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.resetDescription == "20/100 requests")
        #expect(usage.primary?.resetsAt == resetDate)
        #expect(usage.identity?.providerID == .doubao)
    }

    @Test
    func `usage snapshot omits unknown request limit when headers are absent`() {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: now,
            apiKeyValid: true)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `primary label preserves ark request windows`() {
        let arkWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "3/10 requests")
        let codingPlanWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: "30% used")
        let unavailableWindow = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "No usage data")

        #expect(DoubaoProviderDescriptor.primaryLabel(window: arkWindow) == "Requests")
        #expect(DoubaoProviderDescriptor.primaryLabel(window: codingPlanWindow) == nil)
        #expect(DoubaoProviderDescriptor.primaryLabel(window: unavailableWindow) == nil)
    }

    // MARK: - CLI strategy tests

    @Test
    func `cli strategy returns usage from arkcli`() async throws {
        let expectedDate = Date(timeIntervalSince1970: 42)
        let context = Self.makeContext(
            sourceMode: .cli,
            environment: ["ARKCLI_PATH": "/trusted/arkcli"])
        let strategy = DoubaoCLIFetchStrategy(
            cliUsageLoader: { environment in
                #expect(environment["ARKCLI_PATH"] == "/trusted/arkcli")
                return DoubaoUsageSnapshot(
                    remainingRequests: 0,
                    limitRequests: 0,
                    resetTime: nil,
                    updatedAt: expectedDate,
                    apiKeyValid: true,
                    codingPlanUsage: DoubaoCodingPlanUsage(
                        status: "subscribed",
                        updateTime: expectedDate,
                        quotas: [
                            DoubaoCodingPlanUsage.Quota(level: "session", percent: 42.0, resetTime: nil),
                        ]))
            })

        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "cli")
        #expect(result.strategyID == "doubao.cli")
        #expect(result.strategyKind == .cli)
        #expect(result.usage.primary?.usedPercent == 42.0)
    }

    @Test
    func `cli strategy does not cross authentication sources on failure`() {
        let context = Self.makeContext(sourceMode: .auto)
        let strategy = DoubaoCLIFetchStrategy(
            cliUsageLoader: { _ in
                throw DoubaoProviderTestError.signedFailed
            })

        #expect(strategy.shouldFallback(on: DoubaoProviderTestError.signedFailed, context: context) == false)
    }

    @Test
    func `cli strategy does not fall back in explicit cli mode`() {
        let context = Self.makeContext(sourceMode: .cli)
        let strategy = DoubaoCLIFetchStrategy(
            cliUsageLoader: { _ in
                throw DoubaoProviderTestError.signedFailed
            })

        #expect(strategy.shouldFallback(on: DoubaoProviderTestError.signedFailed, context: context) == false)
    }

    @Test
    func `cli cancellation does not fall back to api`() {
        let context = Self.makeContext(sourceMode: .auto)
        let strategy = DoubaoCLIFetchStrategy(
            cliUsageLoader: { _ in
                throw CancellationError()
            })

        #expect(strategy.shouldFallback(on: CancellationError(), context: context) == false)
    }

    // MARK: - API strategy tests

    @Test
    func `api strategy uses ak/sk signed credentials when available`() async throws {
        let expectedDate = Date(timeIntervalSince1970: 99)
        let context = Self.makeContext(
            sourceMode: .api,
            environment: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLTtest",
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "secret123",
            ])
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { credentials in
                #expect(credentials.accessKeyID == "AKLTtest")
                #expect(credentials.secretAccessKey == "secret123")
                return DoubaoUsageSnapshot(
                    remainingRequests: 0,
                    limitRequests: 0,
                    resetTime: nil,
                    updatedAt: expectedDate,
                    apiKeyValid: true,
                    codingPlanUsage: DoubaoCodingPlanUsage(
                        status: "subscribed",
                        updateTime: expectedDate,
                        quotas: [
                            DoubaoCodingPlanUsage.Quota(level: "session", percent: 15.0, resetTime: nil),
                        ]))
            },
            arkUsageLoader: { _ in
                Issue.record("Ark probe should not run when signed credentials succeed")
                throw DoubaoProviderTestError.arkShouldNotRun
            })

        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "api")
        #expect(result.strategyID == "doubao.api")
        #expect(result.strategyKind == .apiToken)
        #expect(result.usage.primary?.usedPercent == 15.0)
    }

    @Test
    func `api strategy falls back to ark key probe when signed credentials fail`() async throws {
        let expectedDate = Date(timeIntervalSince1970: 42)
        let context = Self.makeContext(
            sourceMode: .api,
            environment: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLTtest",
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "secret123",
                DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-env",
            ])
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { _ in
                throw DoubaoProviderTestError.signedFailed
            },
            arkUsageLoader: { apiKey in
                #expect(apiKey == "ark-env")
                return DoubaoUsageSnapshot(
                    remainingRequests: 7,
                    limitRequests: 10,
                    resetTime: expectedDate,
                    updatedAt: expectedDate,
                    apiKeyValid: true)
            })

        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "api")
        #expect(result.usage.primary?.usedPercent == 30)
        #expect(DoubaoProviderDescriptor.primaryLabel(window: result.usage.primary) == "Requests")
    }

    @Test
    func `api strategy does not fall back to cli on failure`() {
        let context = Self.makeContext(sourceMode: .api)
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { _ in
                throw DoubaoProviderTestError.signedFailed
            },
            arkUsageLoader: { _ in
                throw DoubaoProviderTestError.signedFailed
            })

        #expect(strategy.shouldFallback(on: DoubaoProviderTestError.signedFailed, context: context) == false)
    }

    @Test
    func `api strategy uses ark key probe when no ak/sk credentials`() async throws {
        let expectedDate = Date(timeIntervalSince1970: 42)
        let context = Self.makeContext(
            sourceMode: .api,
            environment: [
                DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-env",
            ])
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { _ in
                Issue.record("Signed loader should not run without AK/SK credentials")
                throw DoubaoProviderTestError.signedFailed
            },
            arkUsageLoader: { apiKey in
                #expect(apiKey == "ark-env")
                return DoubaoUsageSnapshot(
                    remainingRequests: 7,
                    limitRequests: 10,
                    resetTime: expectedDate,
                    updatedAt: expectedDate,
                    apiKeyValid: true)
            })

        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "api")
        #expect(result.usage.primary?.usedPercent == 30)
    }

    @Test
    func `api strategy cancellation does not fall back to ark key`() async {
        let context = Self.makeContext(
            sourceMode: .api,
            environment: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLTtest",
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "secret123",
            ])
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { _ in
                throw CancellationError()
            },
            arkUsageLoader: { _ in
                Issue.record("Ark fallback should not run after cancellation")
                throw DoubaoProviderTestError.arkShouldNotRun
            })

        await #expect(throws: CancellationError.self) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `api strategy surfaces signed error when no api key available`() async {
        // AK/SK credentials present but signed request fails, and no Ark API key
        // is configured. The signed error (not a generic "missing key") should surface.
        let context = Self.makeContext(
            sourceMode: .api,
            environment: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLTtest",
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "secret123",
            ])
        let strategy = DoubaoAPIFetchStrategy(
            signedUsageLoader: { _ in
                throw DoubaoUsageError.apiError(403, "SignatureExpired")
            },
            arkUsageLoader: { _ in
                Issue.record("Ark probe should not run when no API key is configured")
                throw DoubaoProviderTestError.arkShouldNotRun
            })

        await #expect {
            try await strategy.fetch(context)
        } throws: { error in
            guard case let DoubaoUsageError.apiError(code, _) = error else { return false }
            return code == 403
        }
    }

    // MARK: - resolveStrategies routing tests

    @Test
    func `auto mode uses cli when api credentials are absent`() async {
        let context = Self.makeContext(sourceMode: .auto)
        let strategies = await DoubaoProviderDescriptor.resolveStrategies(context: context)

        #expect(strategies.count == 1)
        #expect(strategies[0].id == "doubao.cli")
        #expect(strategies[0].kind == .cli)
    }

    @Test
    func `auto mode preserves configured api account over ambient cli`() async {
        let context = Self.makeContext(
            sourceMode: .auto,
            environment: [
                DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-configured-account",
                "ARKCLI_PATH": "/ambient/other-account/arkcli",
            ])
        let strategies = await DoubaoProviderDescriptor.resolveStrategies(context: context)

        #expect(strategies.count == 1)
        #expect(strategies[0].id == "doubao.api")
        #expect(strategies[0].kind == .apiToken)
    }

    @Test
    func `explicit cli mode returns only cli strategy`() async {
        let context = Self.makeContext(sourceMode: .cli)
        let strategies = await DoubaoProviderDescriptor.resolveStrategies(context: context)

        #expect(strategies.count == 1)
        #expect(strategies[0].id == "doubao.cli")
        #expect(strategies[0].kind == .cli)
    }

    @Test
    func `explicit api mode returns only api strategy`() async {
        let context = Self.makeContext(sourceMode: .api)
        let strategies = await DoubaoProviderDescriptor.resolveStrategies(context: context)

        #expect(strategies.count == 1)
        #expect(strategies[0].id == "doubao.api")
        #expect(strategies[0].kind == .apiToken)
    }

    private static func makeContext(
        sourceMode: ProviderSourceMode = .api,
        environment: [String: String] = [:])
        -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: DoubaoProviderTestClaudeFetcher(),
            browserDetection: browserDetection)
    }
}
