import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIHermesUsageTests {
    @Test
    func `hermes usage command is registered and parses source options`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let invocation = try program.resolve(argv: [
            "hermes-usage",
            "--database", "/tmp/one.db,/tmp/two.db",
            "--provider", "codex",
            "--json",
            "--pretty",
            "--refresh-pricing",
        ])

        #expect(invocation.path == ["hermes-usage"])
        #expect(invocation.parsedValues.options["database"] == ["/tmp/one.db,/tmp/two.db"])
        #expect(invocation.parsedValues.options["provider"] == ["codex"])
        #expect(invocation.parsedValues.flags.contains("jsonShortcut"))
        #expect(invocation.parsedValues.flags.contains("pretty"))
        #expect(invocation.parsedValues.flags.contains("refreshPricing"))
    }

    @Test
    func `provider filter accepts every mapped CodexBar provider`() throws {
        let signature = CodexBarCLI._hermesUsageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let providers = Set(HermesUsageProviderMapping.supportedBillingProviders.compactMap {
            HermesUsageProviderMapping.route(for: $0)?.provider
        })

        for provider in providers {
            let parsed = try parser.parse(arguments: ["--provider", provider.rawValue])
            #expect(try CodexBarCLI.decodeHermesUsageProvider(from: parsed) == provider)
        }
    }

    @Test
    func `provider filter rejects unsupported provider`() throws {
        let parser = CommandParser(signature: CodexBarCLI._hermesUsageSignatureForTesting())
        let parsed = try parser.parse(arguments: ["--provider", "cursor"])

        #expect(throws: CLIArgumentError.self) {
            try CodexBarCLI.decodeHermesUsageProvider(from: parsed)
        }
    }

    @Test
    func `database option expands tilde and deduplicates paths`() throws {
        let parser = CommandParser(signature: CodexBarCLI._hermesUsageSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--database", "~/one.db,/tmp/two.db,~/one.db",
        ])

        let urls = CodexBarCLI.decodeHermesUsageDatabaseURLs(
            from: parsed,
            homeDirectory: URL(fileURLWithPath: "/home/test"))

        #expect(urls.map(\.path) == ["/home/test/one.db", "/tmp/two.db"])
    }

    @Test
    func `provider filtering recomputes the top level summary`() throws {
        let report = Self.report()

        let filtered = try CodexBarCLI.filterHermesUsageReport(report, provider: .codex)

        #expect(filtered.providers.map(\.provider) == [.codex])
        #expect(filtered.summary.tokens.total == 160)
        #expect(filtered.summary.subscriptionIncludedTokens == 160)
        #expect(filtered.summary.actualCostUSD == nil)
        #expect(filtered.unmapped.isEmpty)
        #expect(filtered.sources == report.sources)
    }

    @Test
    func `source validation fails when every database is unreadable`() throws {
        let sources = [
            HermesUsageSourceReport(label: "missing", databasePath: "/tmp/missing.db", status: .missing),
            HermesUsageSourceReport(label: "broken", databasePath: "/tmp/broken.db", status: .corrupt),
        ]

        #expect(throws: HermesUsageCLIError.noReadableSources(details: "missing: missing, broken: corrupt")) {
            try CodexBarCLI.validateHermesUsageSources(sources)
        }
    }

    @Test
    func `source validation permits an explicit partial report`() throws {
        let sources = [
            HermesUsageSourceReport(label: "work", databasePath: "/tmp/work.db", status: .read),
            HermesUsageSourceReport(label: "broken", databasePath: "/tmp/broken.db", status: .locked),
        ]

        try CodexBarCLI.validateHermesUsageSources(sources)
    }

    @Test
    func `text output keeps billed included and equivalent costs distinct`() {
        let output = CodexBarCLI.renderHermesUsageText(Self.report(), useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        #expect(output.contains("Hermes local usage snapshot"))
        #expect(output.contains("Actual billed: $1.00"))
        #expect(output.contains("Hermes estimate: $1.25"))
        #expect(output.contains("API-equivalent: ~$0.00"))
        #expect(output.contains("Included in subscription: 160 tokens · 3 requests"))
        #expect(output.contains("Unmapped routes: auto"))
        #expect(output.contains("not exact daily history"))
        #expect(!output.contains("Total billed: $0.00"))
    }

    @Test
    func `json output preserves all cost semantics`() throws {
        let json = try #require(CodexBarCLI.encodeJSON(Self.report(), pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try #require(object["summary"] as? [String: Any])

        #expect(summary["actualCostUSD"] as? Double == 1.0)
        #expect(summary["hermesEstimatedCostUSD"] as? Double == 1.25)
        #expect(summary["apiEquivalentCostUSD"] as? Double == 0.00044815)
        #expect(summary["subscriptionIncludedTokens"] as? Int == 160)
    }

    private static func report() -> HermesUsageReport {
        let codexSummary = HermesUsageSummary(
            tokens: HermesUsageTokenCounts(input: 103, output: 22, cacheRead: 30, cacheWrite: 5, reasoning: 10),
            requests: 3,
            sessions: 1,
            hermesEstimatedCostUSD: nil,
            actualCostUSD: nil,
            subscriptionIncludedTokens: 160,
            subscriptionIncludedRequests: 3,
            apiEquivalentCostUSD: 0.00016075,
            apiEquivalentPricedTokens: 160,
            apiEquivalentUnpricedTokens: 0)
        let claudeSummary = HermesUsageSummary(
            tokens: HermesUsageTokenCounts(input: 40, output: 10, cacheRead: 8, cacheWrite: 4, reasoning: 6),
            requests: 1,
            sessions: 1,
            hermesEstimatedCostUSD: 1.25,
            actualCostUSD: 1.0,
            subscriptionIncludedTokens: 0,
            subscriptionIncludedRequests: 0,
            apiEquivalentCostUSD: 0.0002874,
            apiEquivalentPricedTokens: 62,
            apiEquivalentUnpricedTokens: 0)
        let unmappedSummary = HermesUsageSummary(
            tokens: HermesUsageTokenCounts(input: 9, output: 3),
            requests: 1,
            sessions: 1,
            hermesEstimatedCostUSD: nil,
            actualCostUSD: nil,
            subscriptionIncludedTokens: 0,
            subscriptionIncludedRequests: 0,
            apiEquivalentCostUSD: nil,
            apiEquivalentPricedTokens: 0,
            apiEquivalentUnpricedTokens: 12)
        let overall = HermesUsageSummary(
            tokens: HermesUsageTokenCounts(input: 152, output: 35, cacheRead: 38, cacheWrite: 9, reasoning: 16),
            requests: 5,
            sessions: 3,
            hermesEstimatedCostUSD: 1.25,
            actualCostUSD: 1.0,
            subscriptionIncludedTokens: 160,
            subscriptionIncludedRequests: 3,
            apiEquivalentCostUSD: 0.00044815,
            apiEquivalentPricedTokens: 222,
            apiEquivalentUnpricedTokens: 12)
        return HermesUsageReport(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [
                HermesUsageSourceReport(label: "work", databasePath: "/tmp/state.db", status: .read),
            ],
            summary: overall,
            providers: [
                HermesUsageProviderReport(
                    provider: .codex,
                    billingProviders: ["openai-codex"],
                    summary: codexSummary,
                    models: [],
                    tasks: []),
                HermesUsageProviderReport(
                    provider: .claude,
                    billingProviders: ["anthropic"],
                    summary: claudeSummary,
                    models: [],
                    tasks: []),
            ],
            unmapped: [
                HermesUsageUnmappedReport(
                    billingProvider: "auto",
                    summary: unmappedSummary,
                    models: [],
                    tasks: []),
            ],
            warnings: [
                "Hermes state.db stores cumulative per-session rows; this is a current snapshot, " +
                    "not exact daily history.",
            ])
    }
}
