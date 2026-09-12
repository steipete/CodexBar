import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct OpenAISubscriptionEnrichmentTests {
    private let renewal = Date(timeIntervalSince1970: 1_788_000_000)

    @Test(arguments: [false, true])
    func `menu cards prefer live subscription dates and keep cached fallback account scoped`(
        hasLiveDashboard: Bool) async throws
    {
        let store = try self.makeStore()
        let usage = try #require(store.snapshots[.codex])
        let liveRenewal = self.renewal.addingTimeInterval(86400)
        if hasLiveDashboard {
            let live = self.dashboard(stamp: 200, credits: 20).withSubscriptionMetadata(
                .init(expiresAt: nil, renewsAt: liveRenewal))
            #expect(await store.applyOpenAIDashboard(live, targetEmail: "managed@example.com"))
            await store.widgetSnapshotPersistTask?.value
            #expect(store.openAIDashboardAttachmentAuthorized)
        }
        let cached = self.dashboard(stamp: 100, credits: 10).withSubscriptionMetadata(
            .init(expiresAt: nil, renewsAt: self.renewal))
        OpenAIDashboardCacheStore.save(.init(accountEmail: "managed@example.com", snapshot: cached))
        let expectedRenewal = hasLiveDashboard ? liveRenewal : self.renewal
        #expect(store.presentationSnapshot(for: .codex)?.subscriptionRenewsAt == expectedRenewal)
        let expectedNotes = UsageMenuCardView.Model.subscriptionMetadataNotes(
            snapshot: usage.withSubscriptionMetadata(expiresAt: nil, renewsAt: expectedRenewal),
            provider: .codex)

        try withStatusItemControllerForTesting(
            store: store,
            settings: store.settings,
            fetcher: UsageFetcher(environment: [:]))
        { controller in
            let live = try #require(controller.menuCardModel(for: .codex))
            if hasLiveDashboard,
               let path = ProcessInfo.processInfo.environment["CODEXBAR_SUBSCRIPTION_CACHE_PROOF_FILE"]
            {
                let hosting = NSHostingView(rootView: AnyView(
                    UsageMenuCardView(model: live, width: 370)
                        .padding(16)
                        .environment(\.colorScheme, .light)))
                hosting.appearance = NSAppearance(named: .aqua)
                let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                try png.write(to: URL(fileURLWithPath: path))
            }
            #expect(live.subscriptionNotes == expectedNotes)
            let accountCard = try #require(controller.menuCardModel(for: .codex, snapshotOverride: usage))
            #expect(accountCard.subscriptionNotes.isEmpty)
            let emptyAccountCard = try #require(controller.menuCardModel(for: .codex, forceOverrideCard: true))
            #expect(emptyAccountCard.subscriptionNotes.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `explicit account cards use only their own identity and credit quota`(hasMonthlyQuota: Bool) throws {
        let store = try self.makeStore()
        store.settings.showOptionalCreditsAndExtraUsage = true
        store.settings.hidePersonalInfo = false
        store.settings.usageBarsShowUsed = true
        store.planUtilizationHistoryLoaded = false
        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: Date())
        let now = Date()
        let ownCredits = CreditsSnapshot(
            remaining: 10,
            events: [],
            updatedAt: now,
            codexCreditLimit: hasMonthlyQuota ? CodexCreditLimitSnapshot(
                used: 27, limit: 100, remainingPercent: 73, resetsAt: nil, updatedAt: now) : nil)
        let account = CodexVisibleAccount(
            id: "fixture-other-account",
            email: "other@example.com",
            storedAccountID: nil,
            selectionSource: .profileHome(path: CodexCredentialFixtures.root.appendingPathComponent("other").path),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let ownSnapshot = hasMonthlyQuota ? UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: account.email, accountOrganization: nil, loginMethod: "business")) :
            nil
        let record = CodexAccountUsageSnapshot(
            account: account, snapshot: ownSnapshot, error: nil, sourceLabel: nil, credits: ownCredits)

        try withStatusItemControllerForTesting(
            store: store,
            settings: store.settings,
            fetcher: UsageFetcher(environment: [:]))
        { controller in
            let models = try [
                #require(controller.menuCardModel(
                    for: .codex,
                    snapshotOverride: ownSnapshot,
                    accountOverride: AccountInfo(email: account.email, plan: nil),
                    creditsOverride: ownCredits)),
                #require(controller.codexAccountMenuCardModel(for: account, accountSnapshot: record)),
            ]
            for model in models {
                #expect(model.email == account.email)
                #expect(model.metrics.map(\.percent) == (hasMonthlyQuota ? [27] : []))
                #expect(model.creditsRemaining == nil)
                #expect(model.tokenUsage == nil)
            }
        }
    }

    @Test
    func `late metadata cannot replace a newer dashboard for the same account`() async throws {
        let store = try self.makeStore()
        let original = self.dashboard(stamp: 100, credits: 10)
        let blocker = BlockingSubscriptionMetadataLoader()
        let task = try await self.start(store, dashboard: original, blocker: blocker)
        let newer = self.dashboard(stamp: 200, credits: 20).withSubscriptionMetadata(
            .init(expiresAt: nil, renewsAt: self.renewal.addingTimeInterval(86400)))
        #expect(await store.applyOpenAIDashboard(newer, targetEmail: "managed@example.com"))
        await store.widgetSnapshotPersistTask?.value
        let usage = store.snapshots[.codex]
        var widgetWrites = 0
        store._test_widgetSnapshotSaveOverride = { _ in widgetWrites += 1 }

        await blocker.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await task.value
        await store.widgetSnapshotPersistTask?.value

        #expect(store.openAIDashboard == newer)
        #expect(store.lastOpenAIDashboardSnapshot == newer)
        #expect(OpenAIDashboardCacheStore.load()?.snapshot == newer)
        #expect(try self.encoded(store.snapshots[.codex]) == self.encoded(usage))
        #expect(store.presentationSnapshot(for: .codex)?.subscriptionRenewsAt == newer.subscriptionRenewsAt)
        #expect(widgetWrites == 0)
    }

    @Test
    func `late metadata attaches to newer usage without replacing its fields`() async throws {
        let store = try self.makeStore()
        let dashboard = self.dashboard(stamp: 100, credits: 10)
        let blocker = BlockingSubscriptionMetadataLoader()
        let task = try await self.start(store, dashboard: dashboard, blocker: blocker)
        let newerUsage = UsageSnapshot(
            primary: RateWindow(usedPercent: 67, windowMinutes: 300, resetsAt: self.renewal, resetDescription: nil),
            secondary: RateWindow(usedPercent: 81, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 200),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "managed@example.com",
                accountOrganization: "Fixture",
                loginMethod: "Pro"))
        store.snapshots[.codex] = newerUsage
        var widgetWrites = 0
        store._test_widgetSnapshotSaveOverride = { _ in widgetWrites += 1 }
        await blocker.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await task.value
        await store.widgetSnapshotPersistTask?.value

        #expect(try self.encoded(store.snapshots[.codex]) == self.encoded(
            newerUsage.withSubscriptionMetadata(expiresAt: nil, renewsAt: self.renewal)))
        #expect(store.openAIDashboard == dashboard.withSubscriptionMetadata(.init(
            expiresAt: nil,
            renewsAt: self.renewal)))
        #expect(OpenAIDashboardCacheStore.load()?.snapshot == store.openAIDashboard)
        #expect(store.lastSourceLabels[.codex] == "codex-cli")
        #expect(widgetWrites == 1)
    }

    @Test(arguments: [false, true])
    func `unavailable metadata preserves dates and explicit empty metadata clears them`(
        explicitEmpty: Bool) async throws
    {
        let store = try self.makeStore()
        let dashboard = self.dashboard(stamp: 100, credits: 10).withSubscriptionMetadata(
            .init(expiresAt: nil, renewsAt: self.renewal))
        let blocker = BlockingSubscriptionMetadataLoader()
        let task = try await self.start(store, dashboard: dashboard, blocker: blocker)
        await blocker.resume(explicitEmpty ? .success(nil) : .unavailable)
        await task.value
        await store.widgetSnapshotPersistTask?.value
        let expectedDate = explicitEmpty ? nil : self.renewal
        #expect(store.snapshots[.codex]?.subscriptionRenewsAt == expectedDate)
        #expect(store.presentationSnapshot(for: .codex)?.subscriptionRenewsAt == expectedDate)
        #expect(store.openAIDashboard?.subscriptionRenewsAt == expectedDate)
        #expect(OpenAIDashboardCacheStore.load()?.snapshot.subscriptionRenewsAt == expectedDate)
    }

    @Test(arguments: ["disabled", "workspace", "cancelled"])
    func `metadata cannot publish after access or account authority changes`(change: String) async throws {
        let store = try self.makeStore()
        let dashboard = self.dashboard(stamp: 100, credits: 10)
        let blocker = BlockingSubscriptionMetadataLoader()
        let task = try await self.start(store, dashboard: dashboard, blocker: blocker)
        switch change {
        case "disabled": store.settings.openAIWebAccessEnabled = false
        case "workspace":
            let home = try #require(store.settings._test_activeManagedCodexAccount?.managedHomePath)
            try CodexManagedOpenAIWebTests.writeCodexAuthFile(
                homeURL: URL(fileURLWithPath: home),
                email: "managed@example.com",
                plan: "pro",
                accountId: "other-workspace")
            store.settings.invalidateCodexAccountReconciliationSnapshotCache()
        default: store.invalidateOpenAIDashboardRefreshTask()
        }
        let usage = store.snapshots[.codex]
        let visible = store.openAIDashboard
        let cache = OpenAIDashboardCacheStore.load()?.snapshot
        var widgetWrites = 0
        store._test_widgetSnapshotSaveOverride = { _ in widgetWrites += 1 }
        await blocker.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await task.value
        await store.widgetSnapshotPersistTask?.value
        #expect(try self.encoded(store.snapshots[.codex]) == self.encoded(usage))
        #expect(store.openAIDashboard == visible)
        #expect(OpenAIDashboardCacheStore.load()?.snapshot == cache)
        #expect(widgetWrites == 0)
    }

    @Test
    func `superseded completion cannot clear the replacement task`() async throws {
        let store = try self.makeStore()
        let first = BlockingSubscriptionMetadataLoader()
        let firstTask = try await self.start(store, dashboard: self.dashboard(stamp: 100, credits: 10), blocker: first)
        let second = BlockingSubscriptionMetadataLoader()
        let newer = self.dashboard(stamp: 200, credits: 20)
        let secondTask = try await self.start(store, dashboard: newer, blocker: second)
        let secondToken = store.openAISubscriptionMetadataEnrichmentToken
        await first.resume(.success(.init(expiresAt: self.renewal, renewsAt: nil)))
        await firstTask.value
        #expect(store.openAISubscriptionMetadataEnrichmentToken == secondToken)
        #expect(store.openAISubscriptionMetadataEnrichmentTask != nil)
        #expect(store.openAIDashboard == newer)
        await second.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await secondTask.value
        await store.widgetSnapshotPersistTask?.value
        #expect(store.openAIDashboard == newer.withSubscriptionMetadata(.init(expiresAt: nil, renewsAt: self.renewal)))
        #expect(store.openAISubscriptionMetadataEnrichmentTask == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_SUBSCRIPTION_NATIVE_PROOF"] == "1"))
    func `signed native card shows the asynchronously attached subscription date`() async throws {
        let store = try self.makeStore()
        let blocker = BlockingSubscriptionMetadataLoader()
        let task = try await self.start(store, dashboard: self.dashboard(stamp: 100, credits: 10), blocker: blocker)
        let fixture = CodexExtraUsageFreshnessTests()
        let before = try fixture.card(snapshot: #require(store.presentationSnapshot(for: .codex)), live: nil)
        await blocker.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await task.value
        await store.widgetSnapshotPersistTask?.value
        let after = try fixture.card(snapshot: #require(store.presentationSnapshot(for: .codex)), live: nil)
        #expect(before.subscriptionNotes.isEmpty)
        #expect(after.subscriptionNotes.count == 1)
        #expect(after.subscriptionNotes[0].hasPrefix("Renews:"))
        try captureSubscriptionNativeProof(
            models: [before, after],
            directory: #require(ProcessInfo.processInfo.environment["CODEXBAR_SUBSCRIPTION_PROOF_DIRECTORY"]))
    }

    @Test
    func `production attachment returns usage while subscription metadata is still pending`() async throws {
        let store = try self.makeStore()
        let dashboard = self.dashboard(stamp: 100, credits: 10)
        let blocker = BlockingSubscriptionMetadataLoader()
        store._test_openAISubscriptionMetadataLoaderOverride = { _ in await blocker.result() }
        let refreshToken = UUID()
        store.openAIDashboardRefreshTaskToken = refreshToken
        await store.applyOpenAIDashboardAndScheduleSubscriptionEnrichment(
            dashboard,
            targetEmail: "managed@example.com",
            context: .init(
                targetEmail: "managed@example.com",
                allowCurrentSnapshotFallback: false,
                expectedGuard: store.currentCodexOpenAIWebRefreshGuard(),
                refreshTaskToken: refreshToken,
                allowCodexUsageBackfill: true,
                force: true))
        #expect(store.openAIDashboard == dashboard)
        #expect(store.presentationSnapshot(for: .codex)?.primary?.usedPercent == 18)
        #expect(store.presentationSnapshot(for: .codex)?.subscriptionRenewsAt == nil)
        let task = try #require(store.openAISubscriptionMetadataEnrichmentTask)
        await blocker.waitUntilStarted()
        await blocker.resume(.success(.init(expiresAt: nil, renewsAt: self.renewal)))
        await task.value
        await store.widgetSnapshotPersistTask?.value
        #expect(store.presentationSnapshot(for: .codex)?.subscriptionRenewsAt == self.renewal)
    }

    private func start(
        _ store: UsageStore,
        dashboard: OpenAIDashboardSnapshot,
        blocker: BlockingSubscriptionMetadataLoader) async throws -> Task<Void, Never>
    {
        #expect(await store.applyOpenAIDashboard(dashboard, targetEmail: "managed@example.com"))
        await store.widgetSnapshotPersistTask?.value
        store._test_openAISubscriptionMetadataLoaderOverride = { _ in await blocker.result() }
        store.scheduleOpenAISubscriptionMetadataEnrichment(
            dashboard: dashboard, targetEmail: "managed@example.com", expectedGuard: nil)
        let task = try #require(store.openAISubscriptionMetadataEnrichmentTask)
        await blocker.waitUntilStarted()
        return task
    }

    private func makeStore() throws -> UsageStore {
        let settings = CodexManagedOpenAIWebTests().makeSettingsStore(suite: "subscription-lifecycle")
        let home = CodexCredentialFixtures.root.appendingPathComponent("managed-home")
        try CodexManagedOpenAIWebTests.writeCodexAuthFile(
            homeURL: home, email: "managed@example.com", plan: "pro", accountId: "fixture-workspace")
        let account = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: home.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = account
        settings.codexActiveSource = .managedAccount(id: account.id)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._test_widgetSnapshotSaveOverride = { _ in }
        store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(usedPercent: 18, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: account.email, accountOrganization: nil, loginMethod: "Pro"))
        store.lastSourceLabels[.codex] = "codex-cli"
        let owner = store.currentCodexAccountScopedRefreshGuard()
        store.lastCodexUsagePublicationGuard = owner
        store.lastCodexAccountScopedRefreshGuard = owner
        return store
    }

    private func encoded(_ usage: UsageSnapshot?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(usage)
    }

    private func dashboard(stamp: TimeInterval, credits: Double) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: "managed@example.com",
            codeReviewRemainingPercent: credits,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(usedPercent: credits, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            creditsRemaining: credits,
            accountPlan: "Pro",
            updatedAt: Date(timeIntervalSince1970: stamp))
    }
}

private actor BlockingSubscriptionMetadataLoader {
    private var continuation: CheckedContinuation<OpenAISubscriptionFetchResult, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func result() async -> OpenAISubscriptionFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.startedWaiters.forEach { $0.resume() }
            self.startedWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if self.continuation != nil {
            return
        }
        await withCheckedContinuation { self.startedWaiters.append($0) }
    }

    func resume(_ result: OpenAISubscriptionFetchResult) {
        self.continuation?.resume(returning: result)
        self.continuation = nil
    }
}
