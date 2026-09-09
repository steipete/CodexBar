import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// FP-194 CLI authority isolation: a resolved Hugging Face Web source — whether selected explicitly
/// with `--source web` or persisted in config — is browser-session authority only. It fetches the
/// browser wallet once per command batch and renders it as one provider-level result without any
/// API token-account label or cache key, regardless of configured token accounts or
/// `--all-accounts`.
private actor OverrideCounter {
    private(set) var count = 0

    func increment() {
        self.count += 1
    }
}

@Suite(.serialized)
struct HuggingFaceCLIWebAuthorityTests {
    @Test
    func `explicit web renders one provider level wallet without account attribution`() async throws {
        // The override seam is a single global, so this suite runs serialized and each test
        // resets it before and after.
        CodexBarCLI._test_providerWebFetchOutcomeOverride = nil
        let counter = OverrideCounter()
        defer { CodexBarCLI._test_providerWebFetchOutcomeOverride = nil }
        CodexBarCLI._test_providerWebFetchOutcomeOverride = { [counter] in
            await counter.increment()
            return Self.webOutcome()
        }

        let tokenContext = try Self.makeTokenContext(allAccounts: true, configSource: nil)
        let output = await CodexBarCLI.fetchUsageOutputs(
            provider: .huggingface,
            status: nil,
            tokenContext: tokenContext,
            command: Self.command(format: .json, sourceModeOverride: .web))

        #expect(await counter.count == 1)
        #expect(output.exitCode == .success)
        #expect(output.payload.count == 1)
        #expect(output.payload[0].provider == "huggingface")
        #expect(output.payload[0].account == nil)
        #expect(output.payload[0].cacheAccountKey == nil)
        #expect(output.payload[0].source == "web")
        #expect(output.payload[0].usage?.providerCost?.balance == 42)
        #expect(output.sections.isEmpty)
        #expect(output.cards.isEmpty)
    }

    @Test
    func `persisted web config renders one provider level wallet identically`() async throws {
        CodexBarCLI._test_providerWebFetchOutcomeOverride = nil
        let counter = OverrideCounter()
        defer { CodexBarCLI._test_providerWebFetchOutcomeOverride = nil }
        CodexBarCLI._test_providerWebFetchOutcomeOverride = { [counter] in
            await counter.increment()
            return Self.webOutcome()
        }

        let tokenContext = try Self.makeTokenContext(allAccounts: true, configSource: .web)
        let output = await CodexBarCLI.fetchUsageOutputs(
            provider: .huggingface,
            status: nil,
            tokenContext: tokenContext,
            command: Self.command(format: .json, sourceModeOverride: nil))

        // Persisted Web selection behaves identically to explicit `--source web`: one Web fetch,
        // one provider-level result, no API account attribution.
        #expect(await counter.count == 1)
        #expect(output.exitCode == .success)
        #expect(output.payload.count == 1)
        #expect(output.payload[0].provider == "huggingface")
        #expect(output.payload[0].account == nil)
        #expect(output.payload[0].cacheAccountKey == nil)
        #expect(output.payload[0].source == "web")
        #expect(output.payload[0].usage?.providerCost?.balance == 42)
    }

    @Test
    func `text web output carries no account header`() async throws {
        CodexBarCLI._test_providerWebFetchOutcomeOverride = nil
        defer { CodexBarCLI._test_providerWebFetchOutcomeOverride = nil }
        CodexBarCLI._test_providerWebFetchOutcomeOverride = {
            Self.webOutcome()
        }

        let tokenContext = try Self.makeTokenContext(allAccounts: true, configSource: .web)
        let output = await CodexBarCLI.fetchUsageOutputs(
            provider: .huggingface,
            status: nil,
            tokenContext: tokenContext,
            command: Self.command(format: .text, sourceModeOverride: nil))

        #expect(output.exitCode == .success)
        #expect(output.sections.count == 1)
        #expect(output.sections[0].contains("42"))
        #expect(!output.sections[0].contains("Personal"))
        #expect(!output.sections[0].contains("Work"))
    }

    @Test
    func `cookies off web selection produces no wallet and no account fan-out`() async throws {
        CodexBarCLI._test_providerWebFetchOutcomeOverride = nil
        defer { CodexBarCLI._test_providerWebFetchOutcomeOverride = nil }
        let tokenContext = try Self.makeTokenContext(
            allAccounts: true,
            configSource: nil,
            cookieSource: .off)
        let output = await CodexBarCLI.fetchUsageOutputs(
            provider: .huggingface,
            status: nil,
            tokenContext: tokenContext,
            command: Self.command(format: .json, sourceModeOverride: .web))

        // Zero browser work (cookies are disabled) and no per-account fan-out: exactly one
        // provider-level failure, not one per configured token account.
        #expect(output.exitCode == .failure)
        #expect(output.payload.count == 1)
        #expect(output.payload[0].account == nil)
        #expect(output.payload[0].usage?.providerCost?.balance == nil)
    }

    private static func makeTokenContext(
        allAccounts: Bool,
        configSource: ProviderSourceMode?,
        cookieSource: ProviderCookieSource = .auto) throws -> TokenAccountCLIContext
    {
        let accounts = [
            ProviderTokenAccount(
                id: UUID(),
                label: "Personal",
                token: "hf_personal_token",
                addedAt: 0,
                lastUsed: nil),
            ProviderTokenAccount(
                id: UUID(),
                label: "Work",
                token: "hf_work_token",
                addedAt: 0,
                lastUsed: nil),
        ]
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .huggingface,
                source: configSource,
                cookieSource: cookieSource,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0)),
        ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: allAccounts)
        return try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
    }

    private static func command(
        format: OutputFormat,
        sourceModeOverride: ProviderSourceMode?) -> UsageCommandContext
    {
        UsageCommandContext(
            format: format,
            includeCredits: false,
            sourceModeOverride: sourceModeOverride,
            antigravityPlanDebug: false,
            augmentDebug: false,
            webDebugDumpHTML: false,
            webTimeout: 1,
            verbose: false,
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            jsonOnly: false,
            includeAllCodexAccounts: false,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func webOutcome() -> ProviderFetchOutcome {
        let observedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let cost = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Prepaid credits",
            balance: 42,
            updatedAt: observedAt)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: observedAt,
            identity: nil)
        let result = ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "web",
            strategyID: "huggingface.web",
            strategyKind: .web)
        return ProviderFetchOutcome(result: .success(result), attempts: [])
    }
}
