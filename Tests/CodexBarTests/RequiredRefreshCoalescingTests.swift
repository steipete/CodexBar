import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension CodexBackgroundRefreshCoalescingTests {
    @Test
    func `required refresh requests during a pass share one follow-up`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-required-refresh-follow-up")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        let store = self.makeStore(settings: settings)
        let providerGate = BlockingRequiredProviderRefresh()
        store._test_providerRefreshOverride = { _ in
            await providerGate.run(interaction: ProviderInteractionContext.current)
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
        }

        let firstRefresh = Task { @MainActor in
            await store.refreshForSettingsChange()
        }
        let didStartFirstPass = await providerGate.waitUntilStarted(count: 1)
        #expect(didStartFirstPass)
        guard didStartFirstPass else {
            firstRefresh.cancel()
            store.cancelRequiredRefresh()
            await providerGate.cancelAll()
            await firstRefresh.value
            return
        }

        var laterRefreshes: [Task<Void, Never>] = []
        for expectedGeneration in 2...4 {
            let task = Task { @MainActor in
                await store.refreshForSettingsChange()
            }
            laterRefreshes.append(task)
            for _ in 0..<100 where store.requiredRefreshRequestGeneration < expectedGeneration {
                await Task.yield()
            }
            #expect(store.requiredRefreshRequestGeneration == expectedGeneration)
        }
        #expect(await providerGate.startedCount() == 1)

        await providerGate.resumeNext()
        let didStartFollowUp = await providerGate.waitUntilStarted(count: 2)
        #expect(didStartFollowUp)
        guard didStartFollowUp else {
            firstRefresh.cancel()
            laterRefreshes.forEach { $0.cancel() }
            store.cancelRequiredRefresh()
            await providerGate.cancelAll()
            await firstRefresh.value
            for task in laterRefreshes {
                await task.value
            }
            return
        }
        #expect(store.requiredRefreshCompletedGeneration == 1)

        await providerGate.resumeNext()
        await firstRefresh.value
        for task in laterRefreshes {
            await task.value
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await providerGate.startedCount() == 2)
        #expect(await providerGate.recordedInteractions() == [.background, .background])
        #expect(store.requiredRefreshCompletedGeneration == 4)
        #expect(store.requiredRefreshTask == nil)
        #expect(store.pendingRequiredRefreshRequest == nil)
    }

    @Test
    func `forced dashboard refresh stops a queued stale scheduler before it starts`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-dashboard-prestart-cancellation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        var allowNavigationTimeoutRetries: [Bool] = []
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Fixture",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        store._test_openAIDashboardLoaderOverride = { _, _, allowNavigationTimeoutRetry, _ in
            allowNavigationTimeoutRetries.append(allowNavigationTimeoutRetry)
            return OpenAIDashboardSnapshot(
                signedInEmail: managedAccount.email,
                codeReviewRemainingPercent: 95,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: 25,
                accountPlan: "Pro",
                updatedAt: Date())
        }
        defer {
            store._test_openAIDashboardCookieImportOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
        }

        let currentGuard = store.freshCodexOpenAIWebRefreshGuard()
        let backgroundGuard = CodexAccountScopedRefreshGuard(
            source: currentGuard.source,
            identity: currentGuard.identity,
            accountKey: currentGuard.accountKey,
            authFingerprint: "background-token-material")
        let forcedGuard = CodexAccountScopedRefreshGuard(
            source: currentGuard.source,
            identity: currentGuard.identity,
            accountKey: currentGuard.accountKey,
            authFingerprint: "forced-token-material")
        store.openAIWebAccountDidChange = true

        // Keep both calls on this MainActor turn so the forced request cancels the scheduler
        // before its task body starts.
        store.scheduleOpenAIDashboardRefreshIfNeeded(expectedGuard: backgroundGuard)
        let backgroundTask = try #require(store.openAIDashboardBackgroundRefreshTask)
        await store.refreshOpenAIDashboardIfNeeded(
            force: true,
            expectedGuard: forcedGuard,
            bypassCoalescing: true,
            allowCodexUsageBackfill: false)
        await backgroundTask.value

        #expect(backgroundTask.isCancelled)
        #expect(allowNavigationTimeoutRetries == [true])
        #expect(store.openAIDashboardBackgroundRefreshTask == nil)
        #expect(store.openAIDashboardRefreshTask == nil)
    }

    @Test
    func `forced dashboard enrichment supersedes weaker background request`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-dashboard-supersedes-background")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let dashboardLoader = BlockingManagedOpenAIDashboardLoader()
        var allowNavigationTimeoutRetries: [Bool] = []
        var dashboardInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, allowNavigationTimeoutRetry, _ in
            allowNavigationTimeoutRetries.append(allowNavigationTimeoutRetry)
            dashboardInteractions.append(ProviderInteractionContext.current)
            return try await dashboardLoader.awaitResult()
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
        }

        store.scheduleOpenAIDashboardRefreshIfNeeded(
            expectedGuard: store.freshCodexOpenAIWebRefreshGuard())
        let didStartBackground = await dashboardLoader.waitUntilStartedWithin(count: 1)
        #expect(didStartBackground)
        guard didStartBackground else {
            store.invalidateOpenAIDashboardRefreshTask()
            await dashboardLoader.cancelAll()
            return
        }
        let staleDashboardTask = store.openAIDashboardRefreshTask
        let backgroundTask = store.openAIDashboardBackgroundRefreshTask

        let forcedRefresh = Task { @MainActor in
            await BrowserCookieAccessGate.withExplicitRetry {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await store.refresh(enrichmentMode: .forcedBackground)
                    await store.awaitForcedRefreshEnrichment()
                }
            }
        }
        let didStartForced = await dashboardLoader.waitUntilStartedWithin(count: 2)
        #expect(didStartForced)
        guard didStartForced else {
            forcedRefresh.cancel()
            store.cancelForcedRefreshEnrichment()
            store.invalidateOpenAIDashboardRefreshTask()
            await dashboardLoader.cancelAll()
            await staleDashboardTask?.value
            await backgroundTask?.value
            await forcedRefresh.value
            return
        }
        #expect(staleDashboardTask?.isCancelled == true)
        #expect(backgroundTask?.isCancelled == true)

        await dashboardLoader.resumeNext(with: .failure(URLError(.timedOut)))
        await staleDashboardTask?.value
        await backgroundTask?.value
        #expect(store.lastOpenAIDashboardError == nil)

        await dashboardLoader.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())))
        await forcedRefresh.value

        #expect(allowNavigationTimeoutRetries == [false, true])
        #expect(dashboardInteractions == [.background, .userInitiated])
        #expect(store.openAIDashboard?.creditsRemaining == 25)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `account scoped refresh supersedes weaker background dashboard request`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-account-dashboard-supersedes-background")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let dashboardLoader = BlockingManagedOpenAIDashboardLoader()
        var allowNavigationTimeoutRetries: [Bool] = []
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, allowNavigationTimeoutRetry, _ in
            allowNavigationTimeoutRetries.append(allowNavigationTimeoutRetry)
            return try await dashboardLoader.awaitResult()
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
        }

        store.scheduleOpenAIDashboardRefreshIfNeeded(
            expectedGuard: store.freshCodexOpenAIWebRefreshGuard())
        let didStartBackground = await dashboardLoader.waitUntilStartedWithin(count: 1)
        #expect(didStartBackground)
        guard didStartBackground else {
            store.invalidateOpenAIDashboardRefreshTask()
            await dashboardLoader.cancelAll()
            return
        }
        let staleDashboardTask = store.openAIDashboardRefreshTask
        let backgroundTask = store.openAIDashboardBackgroundRefreshTask

        let accountRefresh = Task { @MainActor in
            await BrowserCookieAccessGate.withExplicitRetry {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await store.refreshCodexAccountScopedState()
                }
            }
        }
        let didStartForced = await dashboardLoader.waitUntilStartedWithin(count: 2)
        #expect(didStartForced)
        guard didStartForced else {
            accountRefresh.cancel()
            store.invalidateOpenAIDashboardRefreshTask()
            await dashboardLoader.cancelAll()
            await staleDashboardTask?.value
            await backgroundTask?.value
            await accountRefresh.value
            return
        }
        #expect(staleDashboardTask?.isCancelled == true)
        #expect(backgroundTask?.isCancelled == true)

        await dashboardLoader.resumeNext(with: .failure(URLError(.timedOut)))
        await staleDashboardTask?.value
        await backgroundTask?.value
        #expect(store.lastOpenAIDashboardError == nil)

        await dashboardLoader.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())))
        await accountRefresh.value

        #expect(allowNavigationTimeoutRetries == [false, true])
        #expect(store.openAIDashboard?.creditsRemaining == 25)
        #expect(store.lastOpenAIDashboardError == nil)
    }

    @Test
    func `forced background refresh detaches stale dashboard before its tail`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-dashboard-detaches-account")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        let alphaAccount = try Self.installManagedAccount(
            email: "alpha@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: alphaAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        store.syncOpenAIWebState()
        let alphaDashboard = OpenAIDashboardSnapshot(
            signedInEmail: alphaAccount.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())
        store.openAIDashboard = alphaDashboard
        store.openAIDashboardAttachmentAuthorized = true
        store.lastOpenAIDashboardSnapshot = alphaDashboard
        store.lastOpenAIDashboardAttachmentAuthorized = true

        let betaAccount = ManagedCodexAccount(
            id: UUID(),
            email: "beta@example.com",
            managedHomePath: "/tmp/codexbar-managed-beta",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let tokenGate = BlockingForcedTokenRefresh()
        store._test_providerRefreshOverride = { provider in
            guard provider == .codex else { return }
            settings._test_activeManagedCodexAccount = betaAccount
            settings.codexActiveSource = .managedAccount(id: betaAccount.id)
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            guard force else { return }
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        defer {
            settings._test_activeManagedCodexAccount = nil
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        #expect(await tokenGate.waitUntilStarted(count: 1))

        #expect(store.openAIDashboard == nil)
        #expect(!store.openAIDashboardAttachmentAuthorized)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(!store.lastOpenAIDashboardAttachmentAuthorized)
        #expect(store.openAIDashboardRequiresLogin)
        #expect(store.hasForcedRefreshEnrichmentInFlight)

        let enrichmentTask = store.forcedRefreshEnrichmentTask
        store.cancelForcedRefreshEnrichment()
        await tokenGate.resumeNext()
        await enrichmentTask?.value
    }

    @Test
    func `forced token tail excludes periodic token sequence`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-token-excludes-timer")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        #expect(await tokenGate.waitUntilStarted(count: 1))

        store.scheduleTokenRefreshForTesting()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tokenGate.recordedCalls().count == 1)

        await tokenGate.resumeNext()
        await store.awaitForcedRefreshEnrichment()

        let calls = await tokenGate.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.force == true)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `forced enrichment excludes timer after token child completes`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-tail-excludes-token-timer")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        let creditsGate = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            try await creditsGate.awaitResult()
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        #expect(await tokenGate.waitUntilStarted(count: 1))
        #expect(await creditsGate.waitUntilStartedWithin(count: 1))

        await tokenGate.resumeNext()
        for _ in 0..<100 where store.tokenRefreshSequenceTask != nil {
            await Task.yield()
        }
        #expect(store.tokenRefreshSequenceTask == nil)
        #expect(store.hasForcedRefreshEnrichmentInFlight)

        store.scheduleTokenRefreshForTesting()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.tokenRefreshSequenceTask == nil)
        #expect(await tokenGate.recordedCalls().count == 1)

        await creditsGate.resumeNext(with: .success(CreditsSnapshot(
            remaining: 25,
            events: [],
            updatedAt: Date())))
        await store.awaitForcedRefreshEnrichment()

        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }
}

private actor BlockingRequiredProviderRefresh {
    private var interactions: [ProviderInteraction] = []
    private var continuations: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func run(interaction: ProviderInteraction) async {
        let id = UUID()
        self.interactions.append(interaction)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.continuations.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilStarted(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.interactions.count < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func startedCount() -> Int {
        self.interactions.count
    }

    func recordedInteractions() -> [ProviderInteraction] {
        self.interactions
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().continuation.resume()
    }

    func cancelAll() {
        let continuations = self.continuations
        self.continuations.removeAll()
        continuations.forEach { $0.continuation.resume() }
    }

    private func cancel(id: UUID) {
        guard let index = self.continuations.firstIndex(where: { $0.id == id }) else { return }
        self.continuations.remove(at: index).continuation.resume()
    }
}
