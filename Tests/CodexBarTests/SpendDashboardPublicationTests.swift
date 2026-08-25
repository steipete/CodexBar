import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SpendDashboardPublicationTests {
    @Test
    func `shared source observation follows regular Codex publication and bucket ownership`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-source-observation")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .claude)
        }
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        // Isolate from any real ~/.codex corpus: this branch gives the spend dashboard longer
        // catch-up slices, so a developer-machine corpus can delay the shared publication past
        // the wait deadline even though the observation semantics are unchanged.
        let isolatedCodexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedCodexHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedCodexHome)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        // Provider-specific by design: claude stays enabled so ownership fingerprints cover an
        // independent provider, but its refresh is pinned to one confirmed-empty publication so the
        // source-revision baseline cannot depend on live network behavior or repeat refreshes.
        // The publication is seeded before the first configuration snapshot, and the override only
        // fires once, so every recompute in this test observes the same `claude:empty:1` revision.
        var claudeSpendSnapshotPinned = false
        store._test_tokenUsageRefreshOverride = { provider, _ in
            guard provider == .claude, !claudeSpendSnapshotPinned else { return }
            claudeSpendSnapshotPinned = true
            store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        }
        defer { store._test_tokenUsageRefreshOverride = nil }
        store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        claudeSpendSnapshotPinned = true
        let initial = SpendDashboardSource.configuration(settings: settings, store: store)
        store.startSharedSpendDashboardPublication()
        defer { store.stopSharedSpendDashboardPublication() }
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.sourceRevisions == initial.sourceRevisions
        }

        store._setTokenSnapshotForTesting(
            Self.input(id: "codex", provider: .codex, cost: 1).snapshot,
            provider: .codex)
        let afterRegularCodexPublication = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.sourceRevisions ==
                afterRegularCodexPublication.sourceRevisions
        }

        #expect(afterRegularCodexPublication.sourceRevisions != initial.sourceRevisions)
        #expect(store.spendDashboardPublication.configuration?.sourceRevisions ==
            afterRegularCodexPublication.sourceRevisions)

        settings.costUsageBucketTimeZoneIdentifier = "Pacific/Kiritimati"
        let rebucketed = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration?.menuOwnershipFingerprint ==
                rebucketed.menuOwnershipFingerprint
        }

        #expect(rebucketed.menuOwnershipFingerprint != afterRegularCodexPublication.menuOwnershipFingerprint)
        #expect(rebucketed.sourceOwnershipFingerprints != afterRegularCodexPublication.sourceOwnershipFingerprints)
        #expect(store.spendDashboardPublication.configuration?.menuOwnershipFingerprint ==
            rebucketed.menuOwnershipFingerprint)
    }

    @Test
    func `synchronizes independent snapshot publications`() async {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-independent-sync")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude)
        }
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        // Seed before observation starts so the post-start publication below has a distinct
        // publication revision. Codex stays disabled: the regular publisher must not mask the
        // independent synchronization under test.
        store._setSpendDashboardTokenSnapshotForTesting(nil, for: .claude)
        store.startSharedSpendDashboardPublication()
        defer { store.stopSharedSpendDashboardPublication() }
        let seeded = SpendDashboardSource.configuration(settings: settings, store: store)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration == seeded
        }

        let refreshedSnapshot = Self.input(id: "claude", provider: .claude, cost: 2.5).snapshot
        store._setSpendDashboardTokenSnapshotForTesting(refreshedSnapshot, for: .claude)

        // The independent publication boundary must schedule the shared-dashboard sync itself;
        // removing that call leaves this assertion green only if the regular publisher is used.
        #expect(store._test_hasPendingSpendDashboardTokenPublicationSync)

        let synchronized = SpendDashboardSource.configuration(settings: settings, store: store)
        #expect(synchronized != seeded)
        await Self.waitUntil {
            store.spendDashboardPublication.configuration == synchronized &&
                store.spendDashboardPublication.inputs.contains { $0.id == "claude" }
        }

        #expect(store.spendDashboardPublication.inputs.first { $0.id == "claude" }?
            .snapshot.last30DaysCostUSD == 2.5)
    }

    @Test
    func `shared publication starts and stops in-flight Codex dashboard catch-up`() async throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-codex-catch-up")
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let missingLiveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: profileHome)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileHome.path]
            config.codexActiveSource = .profileHome(path: profileHome.path)
        }
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: profileHome)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        var statusLoadCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: "pending",
                processedBytes: 1,
                totalBytes: 2,
                completedFiles: 0,
                totalFiles: 1)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            try await Task.sleep(for: .seconds(60))
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }

        store.startSharedSpendDashboardPublication()
        await Self.waitUntil {
            statusLoadCount > 0 && store.spendDashboardCodexCostCatchUpTask != nil
        }
        store.stopSharedSpendDashboardPublication()

        #expect(statusLoadCount > 0)
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(store.spendDashboardCodexCostCatchUpActivity == nil)
    }

    @Test
    func `usage store owns one shared controller and mirrors its publication`() {
        let settings = testSettingsStore(suiteName: "SpendDashboardPublicationTests-shared-owner")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let first = store.sharedSpendDashboardController()
        let second = store.sharedSpendDashboardController()

        #expect(first === second)

        first.update(configuration: SpendDashboardConfiguration(
            costUsageEnabled: false,
            providerIDs: [],
            codexAccountIdentities: []))

        #expect(store.spendDashboardPublication.revision > 0)
        #expect(store.spendDashboardPublication.configuration?.costUsageEnabled == false)
    }

    @Test
    func `controller atomically publishes canonical inputs and source truth states`() async {
        let fixture = Self.fixture()
        let controller = SpendDashboardController(
            requestBuilder: { _ in fixture.request },
            loader: { _ in fixture.result })

        controller.update(configuration: fixture.request.configuration)
        await Self.waitUntil { !controller.isRefreshing }

        let publication = controller.publication
        let sources = Dictionary(uniqueKeysWithValues: publication.sources.map { ($0.id, $0) })
        let inputs = Dictionary(uniqueKeysWithValues: publication.inputs.map { ($0.id, $0) })

        #expect(Set(sources.keys) == ["openai", "claude", "gemini", "codex:first", "codex:second"])
        #expect(sources["openai"]?.state == .available)
        #expect(inputs["openai"]?.id == "openai")
        #expect(sources["claude"]?.state == .confirmedEmpty)
        #expect(inputs["claude"]?.id == nil)
        #expect(sources["gemini"]?.state == .unavailable)
        #expect(inputs["gemini"]?.id == nil)
        #expect(sources["codex:first"]?.state == .available)
        #expect(inputs["codex:first"]?.id == "codex:first")
        #expect(sources["codex:second"]?.state == .available)
        #expect(inputs["codex:second"]?.id == "codex:second")
        #expect(publication.subscriptionCount(providerScope: [.codex, .openai, .claude, .gemini]) == 5)
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD")
        #expect(publication.knownCostSubscriptionCount(
            model: model,
            providerScope: [.codex, .openai, .claude, .gemini]) == 4)
    }

    @Test
    func `profile-home path containing pipe preserves full account identity`() async {
        let pipeContainingPath = "profile:/Users/test|data|home"
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["\(pipeContainingPath)|cache-identity"])
        let request = SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: Self.now,
            force: false)
        let expectedID = "codex:\(pipeContainingPath)"
        let result = SpendDashboardLoadResult(
            inputs: [Self.input(id: expectedID, provider: .codex, cost: 4)],
            failedSourceIDs: [])
        let controller = SpendDashboardController(
            requestBuilder: { _ in request },
            loader: { _ in result })

        controller.update(configuration: configuration)
        await Self.waitUntil { !controller.isRefreshing }

        let sourceIDs = Set(controller.publication.sources.map(\.id))
        #expect(sourceIDs == [expectedID])
        #expect(controller.publication.subscriptionCount(providerScope: [.codex]) == 1)
        #expect(controller.publication.inputs.first?.id == expectedID)
    }

    @Test
    func `failed refresh publishes retained input as stale last known`() async throws {
        let initialConfiguration = Self.configuration(revision: "claude:first")
        let replacementConfiguration = Self.configuration(revision: "claude:second")
        let script = SpendDashboardPublicationScript(
            requests: [
                Self.request(configuration: initialConfiguration),
                Self.request(configuration: replacementConfiguration, unavailableSourceIDs: ["claude"]),
            ],
            results: [
                SpendDashboardLoadResult(
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 3)],
                    failedSourceIDs: []),
                SpendDashboardLoadResult(inputs: [], failedSourceIDs: ["claude"]),
            ])
        let controller = SpendDashboardController(
            requestBuilder: { mode in await script.nextRequest(mode: mode) },
            loader: { request in await script.nextResult(request: request) })

        controller.update(configuration: initialConfiguration)
        await Self.waitUntil { !controller.isRefreshing }
        controller.update(configuration: replacementConfiguration)
        await Self.waitUntil { !controller.isRefreshing && controller.generation == 2 }

        let source = try #require(controller.publication.sources.first { $0.id == "claude" })
        #expect(source.state == .staleLastKnown)
        #expect(controller.publication.inputs.first { $0.id == "claude" }?.snapshot.last30DaysCostUSD == 3)
        let overview = controller.publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD")
        #expect(overview.groups.isEmpty)
    }

    @Test
    func `visible Codex source without a loadable input remains unavailable`() async throws {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["readable|cache-a", "unreadable|cache-b"])
        let request = Self.request(configuration: configuration)
        let result = SpendDashboardLoadResult(
            inputs: [Self.input(id: "codex:readable", provider: .codex, cost: 2)],
            failedSourceIDs: [])
        let controller = SpendDashboardController(
            requestBuilder: { _ in request },
            loader: { _ in result })

        controller.update(configuration: configuration)
        await Self.waitUntil { !controller.isRefreshing }

        let unreadable = try #require(controller.publication.sources.first { $0.id == "codex:unreadable" })
        #expect(unreadable.state == .unavailable)
    }

    @Test
    func `confirmed empty subscription completes the subtotal without adding spend`() {
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: [Self.input(id: "openai", provider: .openai, cost: 7)],
            sources: [
                SpendSourcePublication(
                    id: "openai",
                    provider: .openai,
                    displayName: "OpenAI",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: "claude",
                    provider: .claude,
                    displayName: "Claude",
                    role: .subscription,
                    state: .confirmedEmpty),
            ])
        let scope: Set<UsageProvider> = [.openai, .claude]
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            providerScope: scope)
        let summary = OverviewSpendSummary(
            model: model,
            providerCount: publication.subscriptionCount(providerScope: scope),
            knownCostProviderCount: publication.knownCostSubscriptionCount(model: model, providerScope: scope),
            knownTokenProviderCount: publication.knownTokenSubscriptionCount(model: model, providerScope: scope))

        #expect(summary.providerCoverageText == "1 of 2 subscriptions have spend")
        #expect(!summary.isPartial)
        #expect(summary.primarySpendText == "$7.00")
    }

    @Test
    func `available unpriced source keeps cost subtotal partial`() {
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: [
                Self.input(id: "openai", provider: .openai, cost: 7),
                Self.input(id: "claude", provider: .claude, cost: nil),
            ],
            sources: [
                SpendSourcePublication(
                    id: "openai",
                    provider: .openai,
                    displayName: "OpenAI",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: "claude",
                    provider: .claude,
                    displayName: "Claude",
                    role: .subscription,
                    state: .available),
            ])
        let scope: Set<UsageProvider> = [.openai, .claude]
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            providerScope: scope)
        let summary = OverviewSpendSummary(
            model: model,
            providerCount: publication.subscriptionCount(providerScope: scope),
            knownCostProviderCount: publication.knownCostSubscriptionCount(model: model, providerScope: scope),
            knownTokenProviderCount: publication.knownTokenSubscriptionCount(model: model, providerScope: scope))

        #expect(summary.isPartial)
        #expect(summary.primarySpendText == "~$7.00")
    }

    @Test
    func `hiding every account source leaves no phantom provider denominator`() {
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: [],
            sources: [
                SpendSourcePublication(
                    id: "codex:first",
                    provider: .codex,
                    displayName: "Codex 1",
                    role: .subscription,
                    state: .unavailable),
                SpendSourcePublication(
                    id: "codex:second",
                    provider: .codex,
                    displayName: "Codex 2",
                    role: .subscription,
                    state: .unavailable),
            ])

        #expect(publication.subscriptionCount(
            providerScope: [.codex],
            hiddenSourceIDs: ["codex:first", "codex:second"]) == 0)
    }

    @Test
    func `OpenCodex replacement is one known coverage source for multiple native accounts`() {
        let nativeInputs = [
            Self.input(id: "codex:first", provider: .codex, cost: 2),
            Self.input(id: "codex:second", provider: .codex, cost: 3),
        ]
        let openCodex = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(id: "unused", provider: .codex, cost: 8).snapshot,
            sourceKind: .openCodex)
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: nativeInputs + [openCodex],
            sources: [
                SpendSourcePublication(
                    id: "codex:first",
                    provider: .codex,
                    displayName: "Codex 1",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: "codex:second",
                    provider: .codex,
                    displayName: "Codex 2",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: .codex,
                    displayName: "OpenCodex",
                    role: .enrichment,
                    state: .available),
            ])
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            hideNativeCodexWhenOpenCodexPresent: true,
            providerScope: [.codex])

        #expect(model.groups.flatMap(\.providers).map(\.id) == [SpendDashboardModel.openCodexSourceID])
        #expect(publication.subscriptionCount(
            providerScope: [.codex],
            hideNativeCodexWhenOpenCodexPresent: true) == 1)
        #expect(publication.knownCostSubscriptionCount(
            model: model,
            providerScope: [.codex],
            hideNativeCodexWhenOpenCodexPresent: true) == 1)
    }

    @Test
    func `non-Codex OpenCodex enrichment does not replace native Codex`() {
        let nativeCodex = Self.input(id: "codex:first", provider: .codex, cost: 2)
        let openCodexKimi = SpendDashboardModel.ProviderInput(
            id: "kimi",
            provider: .kimi,
            displayName: "Kimi",
            snapshot: Self.input(id: "unused", provider: .kimi, cost: 8).snapshot,
            sourceKind: .openCodex)
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: [nativeCodex, openCodexKimi],
            sources: [
                SpendSourcePublication(
                    id: nativeCodex.id,
                    provider: .codex,
                    displayName: nativeCodex.displayName,
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: .codex,
                    displayName: "OpenCodex",
                    role: .enrichment,
                    state: .available),
                SpendSourcePublication(
                    id: openCodexKimi.id,
                    provider: .kimi,
                    displayName: openCodexKimi.displayName,
                    role: .enrichment,
                    state: .available),
            ])
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            hideNativeCodexWhenOpenCodexPresent: true,
            providerScope: [.codex, .kimi])

        #expect(Set(model.groups.flatMap(\.providers).map(\.id)) == [nativeCodex.id, openCodexKimi.id])
        #expect(publication.subscriptionCount(
            providerScope: [.codex],
            hideNativeCodexWhenOpenCodexPresent: true) == 1)
        #expect(publication.knownCostSubscriptionCount(
            model: model,
            providerScope: [.codex],
            hideNativeCodexWhenOpenCodexPresent: true) == 1)
    }

    @Test
    func `visible standalone OpenCodex remains when every native Codex account is hidden`() {
        let nativeInputs = [
            Self.input(id: "codex:first", provider: .codex, cost: 2),
            Self.input(id: "codex:second", provider: .codex, cost: 3),
        ]
        let standaloneOpenCodex = SpendDashboardModel.ProviderInput(
            id: UsageProvider.codex.rawValue,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(id: "unused", provider: .codex, cost: 8).snapshot,
            sourceKind: .openCodex)
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: nativeInputs + [standaloneOpenCodex],
            sources: [
                SpendSourcePublication(
                    id: "codex:first",
                    provider: .codex,
                    displayName: "Codex 1",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: "codex:second",
                    provider: .codex,
                    displayName: "Codex 2",
                    role: .subscription,
                    state: .available),
                SpendSourcePublication(
                    id: standaloneOpenCodex.id,
                    provider: .codex,
                    displayName: "OpenCodex",
                    role: .enrichment,
                    state: .available),
                SpendSourcePublication(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: .codex,
                    displayName: "OpenCodex logs",
                    role: .enrichment,
                    state: .available),
            ])
        let hidden: Set = ["codex:first", "codex:second"]
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            hiddenSourceIDs: hidden,
            providerScope: [.codex])

        #expect(model.groups.flatMap(\.providers).map(\.id) == [standaloneOpenCodex.id])
        #expect(publication.subscriptionCount(providerScope: [.codex], hiddenSourceIDs: hidden) == 1)
        #expect(publication.knownCostSubscriptionCount(
            model: model,
            providerScope: [.codex],
            hiddenSourceIDs: hidden) == 1)
    }

    @Test
    func `confirmed empty OpenCodex-only source is a known zero`() {
        let publication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: nil,
            loadedAt: Self.now,
            isRefreshing: false,
            inputs: [],
            sources: [
                SpendSourcePublication(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: .codex,
                    displayName: "OpenCodex",
                    role: .enrichment,
                    state: .confirmedEmpty),
            ])
        let model = publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            providerScope: [.codex])
        let providerCount = publication.subscriptionCount(providerScope: [.codex])
        let knownCostCount = publication.knownCostSubscriptionCount(model: model, providerScope: [.codex])
        let summary = OverviewSpendSummary(
            model: model,
            providerCount: providerCount,
            knownCostProviderCount: knownCostCount,
            knownTokenProviderCount: publication.knownTokenSubscriptionCount(
                model: model,
                providerScope: [.codex]))

        #expect(providerCount == 1)
        #expect(knownCostCount == 1)
        #expect(summary.primarySpendText == "No usage yet")
    }

    @Test
    func `controller publishes one canonical OpenCodex source identity`() async {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [],
            openCodexUsageLogsEnabled: true)
        let request = Self.request(configuration: configuration)
        let openCodex = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(id: "unused", provider: .codex, cost: 8).snapshot,
            sourceKind: .openCodex)
        let controller = SpendDashboardController(
            requestBuilder: { _ in request },
            loader: { _ in
                SpendDashboardLoadResult(
                    inputs: [openCodex],
                    failedSourceIDs: [],
                    openCodexObservation: .available)
            })

        controller.update(configuration: configuration)
        await Self.waitUntil { !controller.isRefreshing }

        #expect(controller.publication.sources.map(\.id) == [SpendDashboardModel.openCodexSourceID])
    }

    @Test
    func `empty and unavailable catalogs have distinct summary copy`() {
        let model = SpendDashboardModel(requestedDays: 30, groups: [])
        let empty = OverviewSpendSummary(
            model: model,
            providerCount: 2,
            knownCostProviderCount: 2,
            knownTokenProviderCount: 2)
        let unavailable = OverviewSpendSummary(
            model: model,
            providerCount: 2,
            knownCostProviderCount: 0,
            knownTokenProviderCount: 0)

        #expect(empty.primarySpendText == "No usage yet")
        #expect(unavailable.primarySpendText == "Spend unavailable")
    }

    @Test
    func `overview projection is synchronous and reuses published inputs without loading`() async {
        let fixture = Self.fixture()
        let calls = SpendDashboardPublicationLoadCounter()
        let controller = SpendDashboardController(
            requestBuilder: { _ in fixture.request },
            loader: { _ in
                await calls.recordLoad()
                return fixture.result
            })

        controller.update(configuration: fixture.request.configuration)
        await Self.waitUntil { !controller.isRefreshing }
        let callsBeforeProjection = await calls.count

        let model = controller.publication.model(
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "USD",
            providerScope: [.codex])
        let providerIDs = model.groups.flatMap { group in
            group.providers.map(\.id)
        }

        #expect(await calls.count == callsBeforeProjection)
        #expect(Set(providerIDs) == ["codex:first", "codex:second"])
        #expect(model.groups.first?.totalCost == 5)
    }

    private static func fixture() -> (request: SpendDashboardLoadRequest, result: SpendDashboardLoadResult) {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [
                UsageProvider.codex.rawValue,
                UsageProvider.openai.rawValue,
                UsageProvider.claude.rawValue,
                UsageProvider.gemini.rawValue,
            ],
            codexAccountIdentities: ["first|first-cache", "second|second-cache"])
        let openAI = Self.input(id: "openai", provider: .openai, cost: 7)
        return (
            request: SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [openAI],
                unavailableSourceIDs: ["gemini"],
                confirmedEmptySourceIDs: ["claude"],
                codexRequests: [],
                now: Self.now,
                force: false),
            result: SpendDashboardLoadResult(
                inputs: [
                    openAI,
                    Self.input(id: "codex:first", provider: .codex, cost: 2),
                    Self.input(id: "codex:second", provider: .codex, cost: 3),
                ],
                failedSourceIDs: ["gemini"]))
    }

    private static func configuration(revision: String) -> SpendDashboardConfiguration {
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [],
            sourceOwnershipFingerprints: ["claude:stable-owner"],
            sourceRevisions: [revision])
    }

    private static func request(
        configuration: SpendDashboardConfiguration,
        unavailableSourceIDs: Set<String> = []) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: unavailableSourceIDs,
            codexRequests: [],
            now: self.now,
            force: false)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        cost: Double?) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 10,
                last30DaysCostUSD: cost,
                currencyCode: "USD",
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-07-15",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 10,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: self.now))
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        // Loaded macOS CI can stall MainActor startup long enough for a seeded confirmed-empty
        // snapshot to age out; wait well past that boundary before treating publication as absent.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for Spend Dashboard publication")
    }

    private static func writeCodexAuthFile(homeURL: URL) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "shared-publication@example.com",
            "chatgpt_plan_type": "pro",
        ])
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let token = "\(base64URL(header)).\(base64URL(payload))."
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": token,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private actor SpendDashboardPublicationScript {
    private var requests: [SpendDashboardLoadRequest]
    private var results: [SpendDashboardLoadResult]

    init(requests: [SpendDashboardLoadRequest], results: [SpendDashboardLoadResult]) {
        self.requests = requests
        self.results = results
    }

    func nextRequest(mode: SpendDashboardRequestBuildMode) -> SpendDashboardLoadRequest {
        precondition(!self.requests.isEmpty, "Unexpected Spend Dashboard publication request")
        let request = self.requests.removeFirst()
        return SpendDashboardLoadRequest(
            configuration: request.configuration,
            capturedInputs: request.capturedInputs,
            unavailableSourceIDs: request.unavailableSourceIDs,
            confirmedEmptySourceIDs: request.confirmedEmptySourceIDs,
            codexRequests: request.codexRequests,
            now: request.now,
            force: mode.forcesLoader)
    }

    func nextResult(request: SpendDashboardLoadRequest) -> SpendDashboardLoadResult {
        guard !self.results.isEmpty else {
            Issue.record("Unexpected Spend Dashboard publication load for \(request.configuration.providerIDs)")
            return SpendDashboardLoadResult(inputs: [], failedSourceIDs: [])
        }
        return self.results.removeFirst()
    }
}

private actor SpendDashboardPublicationLoadCounter {
    private(set) var count = 0

    func recordLoad() {
        self.count += 1
    }
}
