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

    @Test
    func `signed credential failure falls back to ark API key`() async throws {
        let expectedDate = Date(timeIntervalSince1970: 42)
        let context = Self.makeContext(environment: [
            DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-env",
            DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLT-env",
            DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "sk-env",
        ])
        let strategy = DoubaoAPIFetchStrategy(
            codingPlanUsageLoader: { credentials in
                #expect(credentials.accessKeyID == "AKLT-env")
                #expect(credentials.secretAccessKey == "sk-env")
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
        #expect(result.strategyID == "doubao.api")
        #expect(result.usage.updatedAt == expectedDate)
        #expect(result.usage.primary?.usedPercent == 30)
        #expect(DoubaoProviderDescriptor.primaryLabel(window: result.usage.primary) == "Requests")
    }

    @Test
    func `signed credential cancellation does not fall back to ark API key`() async {
        let context = Self.makeContext(environment: [
            DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-env",
            DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLT-env",
            DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "sk-env",
        ])
        let strategy = DoubaoAPIFetchStrategy(
            codingPlanUsageLoader: { _ in
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

    private static func makeContext(environment: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
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
