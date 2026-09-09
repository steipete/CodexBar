import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

/// FP-194 store-level dual-source coverage: the per-account Auto fetch may only prove a *local*
/// bearer/browser identity match; global uniqueness is decided by the batch post-pass, and
/// provider-level wallet state follows deterministic publication rules.
private struct HuggingFaceWalletOutcomeStubStrategy: ProviderFetchStrategy {
    enum Mode: Sendable {
        case compose(Set<UUID>)
        case providerLevelUnverified
        case unavailable
        case failAPI
    }

    let mode: Mode
    let balanceUSD: Double

    let id = "huggingface.js"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        switch self.mode {
        case .failAPI:
            throw ProviderPluginError.script("fixture API outage")
        case .unavailable:
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.unavailable)
        case .providerLevelUnverified:
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: self.balanceUSD,
                    observedAt: Date(),
                    attribution: .unverified)))
        case let .compose(matchingAccountIDs):
            let isLocalMatch = context.selectedTokenAccountID.map { matchingAccountIDs.contains($0) } ?? false
            if isLocalMatch {
                let observedAt = Date()
                let usage = Self.apiUsage(context: context, balanceUSD: self.balanceUSD, observedAt: observedAt)
                return self.makeResult(usage: usage, sourceLabel: "api+web")
                    .replacingWalletOutcome(.localMatchComposed(
                        balanceUSD: self.balanceUSD,
                        observedAt: observedAt))
            }
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: self.balanceUSD,
                    observedAt: Date(),
                    attribution: .unverified)))
        }
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func apiUsage(
        context _: ProviderFetchContext,
        balanceUSD: Double?,
        observedAt: Date? = nil) -> UsageSnapshot
    {
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Reported billing period",
            balance: balanceUSD,
            balanceUpdatedAt: observedAt,
            updatedAt: Date())
        return UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: Date(), identity: nil)
    }
}

@MainActor
@Suite(.serialized)
struct HuggingFaceDualSourceStoreTests {
    @Test
    func `stacked batch composes the wallet only for the uniquely matching account`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-unique",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [0])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.count == 2)
        #expect(snapshots[0].snapshot?.providerCost?.balance == 9.25)
        #expect(snapshots[0].snapshot?.providerCost?.balanceUpdatedAt != nil)
        #expect(snapshots[0].sourceLabel == "api+web")
        #expect(snapshots[1].snapshot?.providerCost?.balance == nil)
        #expect(snapshots[1].sourceLabel == "api")
        // Unique composition owns the wallet; no provider-level duplicate remains.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
    }

    @Test
    func `multiple matching accounts are stripped and the wallet renders once at provider level`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-multi-match",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [0, 1])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.snapshot?.providerCost?.balance == nil })
        #expect(snapshots.allSatisfy { $0.sourceLabel == "api" })
        let publication = try #require(fixture.store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .multipleMatchingAccounts)
    }

    @Test
    func `zero matching accounts publish one unverified provider-level wallet`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-zero-match",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.allSatisfy { $0.snapshot?.providerCost?.balance == nil })
        let publication = try #require(fixture.store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .unverified)
    }

    @Test
    func `unavailable wallet attempts clear a prior provider-level publication`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-unavailable",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [],
            mode: .unavailable)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(),
            attribution: .unverified)

        await fixture.store.refreshProvider(.huggingface)

        // Attempted-and-unavailable must not keep presenting stale Credits as current.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
    }

    @Test
    func `configuration driven clearing removes the wallet even when the API fetch fails`() async throws {
        for source in [ProviderCookieSource.off, nil] {
            let fixture = try Self.makeFixture(
                suite: "hf-dual-source-config-clear-\(source.map(\.rawValue) ?? "api")",
                accountTokens: ["hf_personal_token", "hf_work_token"],
                matchingIndices: [],
                mode: .failAPI)
            fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
                balanceUSD: 42,
                observedAt: Date(),
                attribution: .unverified)
            if let source {
                fixture.settings.huggingFaceCookieSource = source
            } else {
                fixture.settings.huggingFaceUsageDataSource = .api
            }

            // The API fetch intentionally fails and its error is stored, not thrown.
            await fixture.store.refreshProvider(.huggingface)

            // Explicitly disabling the browser authority (cookies Off or isolated API mode)
            // clears the wallet regardless of the API outcome.
            #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
        }
    }

    @Test
    func `ordinary auto API failure before wallet work preserves prior state`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-failure-preserves",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [],
            mode: .failAPI)
        fixture.settings.huggingFaceCookieSource = .manual
        fixture.settings.huggingFaceManualCookieHeader = "session=fixture"
        let prior = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(),
            attribution: .unverified)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = prior

        // The API fetch intentionally fails and its error is stored, not thrown.
        await fixture.store.refreshProvider(.huggingface)

        // Browser use remains configured, so the failed refresh makes no wallet transition.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == prior)
    }

    @Test
    func `cli batch decision strips ambiguous compositions and publishes one provider wallet`() {
        let accountA = ProviderTokenAccount(
            id: UUID(),
            label: "A",
            token: "hf_a",
            addedAt: 0,
            lastUsed: nil)
        let accountB = ProviderTokenAccount(
            id: UUID(),
            label: "B",
            token: "hf_b",
            addedAt: 0,
            lastUsed: nil)
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            Self.batchEntry(account: accountA, composed: true),
            Self.batchEntry(account: accountB, composed: true),
        ])

        guard case let .providerLevel(publication) = batch.decision else {
            Issue.record("Expected a provider-level decision for multiple matching accounts")
            return
        }
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .multipleMatchingAccounts)
        #expect(batch.entries.count == 2)
        for entry in batch.entries {
            guard case let .success(result) = entry.outcome.result else {
                Issue.record("Expected a successful batch entry")
                continue
            }
            #expect(result.sourceLabel == "api")
            #expect(result.usage.providerCost?.balance == nil)
            #expect(result.huggingFaceWalletOutcome == nil)
        }
    }

    @Test
    func `cli batch decision keeps unique composition and renders no provider duplicate`() {
        let accountA = ProviderTokenAccount(
            id: UUID(),
            label: "A",
            token: "hf_a",
            addedAt: 0,
            lastUsed: nil)
        let accountB = ProviderTokenAccount(
            id: UUID(),
            label: "B",
            token: "hf_b",
            addedAt: 0,
            lastUsed: nil)
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            Self.batchEntry(account: accountA, composed: true),
            Self.batchEntry(account: accountB, composed: false),
        ])

        // The unique composition owns the wallet; the mismatched account's provisional
        // provider-level outcome must not render a second copy of the same wallet.
        guard case .composedOnAccount = batch.decision else {
            Issue.record("Expected a composed-on-account decision for a unique match")
            return
        }
        guard case let .success(keptResult) = batch.entries[0].outcome.result else {
            Issue.record("Expected the unique composition to survive")
            return
        }
        #expect(keptResult.sourceLabel == "api+web")
        #expect(keptResult.usage.providerCost?.balance == 9.25)
    }

    @Test
    func `cli batch decision publishes one unverified provider wallet when nothing composes`() {
        let accountA = ProviderTokenAccount(
            id: UUID(),
            label: "A",
            token: "hf_a",
            addedAt: 0,
            lastUsed: nil)
        let accountB = ProviderTokenAccount(
            id: UUID(),
            label: "B",
            token: "hf_b",
            addedAt: 0,
            lastUsed: nil)
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            Self.batchEntry(account: accountA, composed: false),
            Self.batchEntry(account: accountB, composed: false),
        ])

        guard case let .providerLevel(publication) = batch.decision else {
            Issue.record("Expected a provider-level decision for zero matching accounts")
            return
        }
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .unverified)
        #expect(batch.entries.count == 2)
    }

    @Test
    func `cli single account mismatch decides one provider wallet`() {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Only",
            token: "hf_only",
            addedAt: 0,
            lastUsed: nil)
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            Self.batchEntry(account: account, composed: false),
        ])

        guard case let .providerLevel(publication) = batch.decision else {
            Issue.record("Expected a provider-level wallet for a single-account mismatch")
            return
        }
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .unverified)
    }

    @Test
    func `cli single account composition stays on the account`() {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Only",
            token: "hf_only",
            addedAt: 0,
            lastUsed: nil)
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            Self.batchEntry(account: account, composed: true),
        ])

        guard case .composedOnAccount = batch.decision else {
            Issue.record("Expected the composed wallet to stay on the single account")
            return
        }
    }

    @Test
    func `cli batch with failed fetches makes no wallet transition`() {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Only",
            token: "hf_only",
            addedAt: 0,
            lastUsed: nil)
        let outcome = ProviderFetchOutcome(
            result: .failure(ProviderPluginError.script("fixture API outage")),
            attempts: [])
        let batch = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            (account, outcome),
        ])

        guard case .noTransition = batch.decision else {
            Issue.record("Expected no wallet transition when every fetch failed before wallet work")
            return
        }
    }

    @Test
    func `provider level wallet output renders once across text cards and json`() async {
        let publication = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .multipleMatchingAccounts)
        let decision = HuggingFaceWalletBatchDecision.providerLevel(publication)

        // Text renders exactly one wallet section.
        var textOutput = UsageCommandOutput()
        await CodexBarCLI.appendHuggingFaceProviderWalletOutput(
            decision: decision,
            status: nil,
            command: Self.renderCommand(format: .text, cardsLayout: false),
            output: &textOutput)
        #expect(textOutput.sections.count == 1)
        #expect(textOutput.sections[0].contains("Browser session wallet"))
        #expect(textOutput.sections[0].contains("9.25"))
        #expect(textOutput.payload.isEmpty)
        #expect(textOutput.cards.isEmpty)

        // Cards render exactly one wallet card.
        var cardsOutput = UsageCommandOutput()
        await CodexBarCLI.appendHuggingFaceProviderWalletOutput(
            decision: decision,
            status: nil,
            command: Self.renderCommand(format: .text, cardsLayout: true),
            output: &cardsOutput)
        #expect(cardsOutput.cards.count == 1)
        #expect(cardsOutput.cards[0].provider == .huggingface)
        #expect(cardsOutput.sections.isEmpty)
        #expect(cardsOutput.payload.isEmpty)

        // JSON renders exactly one provider-level payload without account attribution.
        var jsonOutput = UsageCommandOutput()
        await CodexBarCLI.appendHuggingFaceProviderWalletOutput(
            decision: decision,
            status: nil,
            command: Self.renderCommand(format: .json, cardsLayout: false),
            output: &jsonOutput)
        #expect(jsonOutput.payload.count == 1)
        #expect(jsonOutput.payload[0].provider == "huggingface")
        #expect(jsonOutput.payload[0].account == nil)
        #expect(jsonOutput.payload[0].cacheAccountKey == nil)
        #expect(jsonOutput.payload[0].source == "web")
        #expect(jsonOutput.payload[0].usage?.details.first?.title == "Browser session wallet")
        #expect(jsonOutput.sections.isEmpty)
        #expect(jsonOutput.cards.isEmpty)
    }

    @Test
    func `provider wallet output renders nothing when an account owns the composition`() async {
        var output = UsageCommandOutput()
        await CodexBarCLI.appendHuggingFaceProviderWalletOutput(
            decision: .composedOnAccount,
            status: nil,
            command: Self.renderCommand(format: .json, cardsLayout: false),
            output: &output)
        #expect(output.payload.isEmpty)
        #expect(output.sections.isEmpty)
        #expect(output.cards.isEmpty)

        var clearedOutput = UsageCommandOutput()
        await CodexBarCLI.appendHuggingFaceProviderWalletOutput(
            decision: .clear,
            status: nil,
            command: Self.renderCommand(format: .json, cardsLayout: false),
            output: &clearedOutput)
        #expect(clearedOutput.payload.isEmpty)
    }

    private static func renderCommand(format: OutputFormat, cardsLayout: Bool) -> UsageCommandContext {
        UsageCommandContext(
            format: format,
            includeCredits: false,
            sourceModeOverride: nil,
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
            browserDetection: BrowserDetection(cacheTTL: 0),
            cardsLayout: cardsLayout)
    }

    private static func batchEntry(
        account: ProviderTokenAccount,
        composed: Bool) -> (account: ProviderTokenAccount?, outcome: ProviderFetchOutcome)
    {
        let observedAt = Date()
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Reported billing period",
            balance: composed ? 9.25 : nil,
            balanceUpdatedAt: composed ? observedAt : nil,
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
            sourceLabel: composed ? "api+web" : "api",
            strategyID: "huggingface.js",
            strategyKind: .apiToken,
            huggingFaceWalletOutcome: composed
                ? .localMatchComposed(balanceUSD: 9.25, observedAt: observedAt)
                : .providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: 9.25,
                    observedAt: observedAt,
                    attribution: .unverified)))
        return (account, ProviderFetchOutcome(result: .success(result), attempts: []))
    }

    private struct Fixture {
        let store: UsageStore
        let settings: SettingsStore
    }

    private static func makeFixture(
        suite: String,
        accountTokens: [String],
        matchingIndices: Set<Int>,
        mode: HuggingFaceWalletOutcomeStubStrategy.Mode = .compose([])) throws -> Fixture
    {
        let settings = testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.multiAccountMenuLayout = .stacked
        settings.huggingFaceCookieSource = .manual
        settings.huggingFaceManualCookieHeader = "session=fixture"
        for (index, token) in accountTokens.enumerated() {
            settings.addTokenAccount(provider: .huggingface, label: "Account \(index)", token: token)
        }
        let accounts = settings.tokenAccounts(for: .huggingface)
        let matchingAccountIDs = Set(accounts.indices
            .filter { matchingIndices.contains($0) }
            .compactMap { accounts[$0].id })
        let resolvedMode: HuggingFaceWalletOutcomeStubStrategy.Mode = switch mode {
        case .compose:
            .compose(matchingAccountIDs)
        case .providerLevelUnverified, .unavailable, .failAPI:
            mode
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let baseDescriptor = baseSpec.descriptor
        let stub = HuggingFaceWalletOutcomeStubStrategy(mode: resolvedMode, balanceUSD: 9.25)
        store.providerSpecs[.huggingface] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .huggingface,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api, .web],
                    pipeline: ProviderFetchPipeline { _ in [stub] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return Fixture(store: store, settings: settings)
    }
}
