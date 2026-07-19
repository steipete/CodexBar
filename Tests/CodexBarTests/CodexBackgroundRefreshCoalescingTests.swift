import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexBackgroundRefreshCoalescingTests {
    @Test
    func `rapid regular refreshes coalesce concurrent Codex credits fetches`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-coalescing")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        let firstCompletion = RefreshCompletionProbe()
        let secondCompletion = RefreshCompletionProbe()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let firstRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await firstCompletion.markCompleted()
        }
        let didStartFirstCreditsRefresh = await blocker.waitUntilStartedWithin(count: 1)
        #expect(didStartFirstCreditsRefresh)
        guard didStartFirstCreditsRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [firstRefreshTask])
            return
        }
        let didCompleteFirstRefresh = await firstCompletion.waitUntilCompleted()
        #expect(didCompleteFirstRefresh)
        guard didCompleteFirstRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [firstRefreshTask])
            return
        }

        let secondRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await secondCompletion.markCompleted()
        }

        let didCompleteSecondRefresh = await secondCompletion.waitUntilCompleted()
        #expect(didCompleteSecondRefresh)
        guard didCompleteSecondRefresh else {
            await self.cancelCreditsWork(
                store: store,
                blocker: blocker,
                tasks: [firstRefreshTask, secondRefreshTask])
            return
        }
        #expect(await blocker.startedCount() == 1)

        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))

        await firstRefreshTask.value
        await secondRefreshTask.value
    }

    @Test
    func `regular credits refresh reschedules when Codex account changes`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-account-switch")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let alphaAccount = try Self.makeManagedAccount(email: "alpha@example.com")
        let betaAccount = try Self.makeManagedAccount(email: "beta@example.com")
        defer {
            try? FileManager.default.removeItem(atPath: alphaAccount.managedHomePath)
            try? FileManager.default.removeItem(atPath: betaAccount.managedHomePath)
        }
        settings._test_activeManagedCodexAccount = alphaAccount
        settings.codexActiveSource = .managedAccount(id: alphaAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let alphaRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
        }
        let didStartAlphaRefresh = await blocker.waitUntilStartedWithin(count: 1)
        #expect(didStartAlphaRefresh)
        guard didStartAlphaRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [alphaRefreshTask])
            return
        }
        let staleCreditsTask = try #require(store.creditsRefreshTask)

        settings._test_activeManagedCodexAccount = betaAccount
        settings.codexActiveSource = .managedAccount(id: betaAccount.id)
        let betaRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
        }
        let didStartBetaRefresh = await blocker.waitUntilStartedWithin(count: 2)
        #expect(didStartBetaRefresh)
        guard didStartBetaRefresh else {
            await self.cancelCreditsWork(
                store: store,
                blocker: blocker,
                tasks: [alphaRefreshTask, betaRefreshTask])
            return
        }

        let didCancelAlphaRefresh = await blocker.waitUntilCancellationCount(1)
        #expect(didCancelAlphaRefresh)
        guard didCancelAlphaRefresh else {
            await self.cancelCreditsWork(
                store: store,
                blocker: blocker,
                tasks: [alphaRefreshTask, betaRefreshTask])
            return
        }
        await blocker.resumeLast(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))

        await alphaRefreshTask.value
        await betaRefreshTask.value
        await staleCreditsTask.value
        await store.creditsRefreshTask?.value

        #expect(await blocker.startedCount() == 2)
        #expect(store.lastCreditsSnapshotAccountKey == "beta@example.com")
        #expect(store.credits?.remaining == 25)
    }

    @Test
    func `force refresh cancels stale background Codex credits fetch`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-force-cancels-background")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let regularCompletion = RefreshCompletionProbe()

        let regularRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await regularCompletion.markCompleted()
        }
        let didStartRegularCreditsRefresh = await blocker.waitUntilStartedWithin(count: 1)
        #expect(didStartRegularCreditsRefresh)
        guard didStartRegularCreditsRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [regularRefreshTask])
            return
        }
        let didCompleteRegularRefresh = await regularCompletion.waitUntilCompleted()
        #expect(didCompleteRegularRefresh)
        guard didCompleteRegularRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [regularRefreshTask])
            return
        }
        let staleCreditsTask = try #require(store.creditsRefreshTask)

        let forceRefreshTask = Task {
            await store.refresh(forceTokenUsage: true)
        }
        let didStartForcedCreditsRefresh = await blocker.waitUntilStartedWithin(count: 2)
        #expect(didStartForcedCreditsRefresh)
        guard didStartForcedCreditsRefresh else {
            await self.cancelCreditsWork(
                store: store,
                blocker: blocker,
                tasks: [regularRefreshTask, forceRefreshTask])
            return
        }

        let didCancelStaleCreditsRefresh = await blocker.waitUntilCancellationCount(1)
        #expect(didCancelStaleCreditsRefresh)
        guard didCancelStaleCreditsRefresh else {
            await self.cancelCreditsWork(
                store: store,
                blocker: blocker,
                tasks: [regularRefreshTask, forceRefreshTask])
            return
        }
        await blocker.resumeLast(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))

        await regularRefreshTask.value
        await forceRefreshTask.value
        await staleCreditsTask.value

        #expect(await blocker.startedCount() == 2)
        #expect(await blocker.cancellationCount() == 1)
        #expect(store.credits?.remaining == 25)
    }

    @Test
    func `forced background tail replaces stale scheduled Codex credits fetch`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-tail-cancels-background")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
        }

        await store.refresh(forceTokenUsage: false)
        let didStartScheduledCreditsRefresh = await blocker.waitUntilStartedWithin(count: 1)
        #expect(didStartScheduledCreditsRefresh)
        guard didStartScheduledCreditsRefresh else {
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [])
            return
        }
        let staleCreditsTask = try #require(store.creditsRefreshTask)

        await store.refresh(enrichmentMode: .forcedBackground)
        let tailTask = try #require(store.forcedRefreshEnrichmentTask)
        let didStartForcedCreditsRefresh = await blocker.waitUntilStartedWithin(count: 2)
        #expect(didStartForcedCreditsRefresh)
        guard didStartForcedCreditsRefresh else {
            tailTask.cancel()
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [tailTask])
            return
        }

        let didCancelStaleCreditsRefresh = await blocker.waitUntilCancellationCount(1)
        #expect(didCancelStaleCreditsRefresh)
        guard didCancelStaleCreditsRefresh else {
            tailTask.cancel()
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [tailTask])
            return
        }
        await blocker.resumeLast(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))
        await tailTask.value
        await staleCreditsTask.value

        #expect(await blocker.startedCount() == 2)
        #expect(await blocker.cancellationCount() == 1)
        #expect(store.credits?.remaining == 25)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `rapid regular refreshes coalesce concurrent OpenAI dashboard fetches`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-dashboard-coalescing")
        settings.statusChecksEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        let firstCompletion = RefreshCompletionProbe()
        let secondCompletion = RefreshCompletionProbe()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        await store.refresh(forceTokenUsage: false)

        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let firstRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await firstCompletion.markCompleted()
        }
        let didStartDashboardRefresh = await blocker.waitUntilStartedWithin(count: 1)
        #expect(didStartDashboardRefresh)
        guard didStartDashboardRefresh else {
            await self.cancelDashboardWork(store: store, blocker: blocker, tasks: [firstRefreshTask])
            return
        }
        let didCompleteFirstRefresh = await firstCompletion.waitUntilCompleted()
        #expect(didCompleteFirstRefresh)
        guard didCompleteFirstRefresh else {
            await self.cancelDashboardWork(store: store, blocker: blocker, tasks: [firstRefreshTask])
            return
        }

        let secondRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await secondCompletion.markCompleted()
        }

        let didCompleteSecondRefresh = await secondCompletion.waitUntilCompleted()
        #expect(didCompleteSecondRefresh)
        guard didCompleteSecondRefresh else {
            await self.cancelDashboardWork(
                store: store,
                blocker: blocker,
                tasks: [firstRefreshTask, secondRefreshTask])
            return
        }
        #expect(await blocker.startedCount() == 1)

        let backgroundTask = try #require(store.openAIDashboardBackgroundRefreshTask)
        await blocker.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())))

        await firstRefreshTask.value
        await secondRefreshTask.value
        await backgroundTask.value

        #expect(store.openAIDashboard?.creditsRemaining == 25)
    }

    @Test
    func `cancelled background dashboard import does not publish stale account status`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-dashboard-cancelled-import")
        settings.statusChecksEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let importBlocker = BlockingOpenAIDashboardCookieImport()
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            try await importBlocker.awaitResult()
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let importTask = Task { @MainActor in
            await store.importOpenAIDashboardCookiesIfNeeded(
                targetEmail: managedAccount.email,
                force: true)
        }
        let didStartImport = await importBlocker.waitUntilStarted()
        #expect(didStartImport)
        guard didStartImport else {
            importTask.cancel()
            await importBlocker.cancelAll()
            _ = await importTask.value
            return
        }
        importTask.cancel()
        let didObserveCancellation = await importBlocker.waitUntilCancellationCount(1)
        #expect(didObserveCancellation)
        guard didObserveCancellation else {
            await importBlocker.cancelAll()
            _ = await importTask.value
            return
        }
        await importBlocker.resumeNext(with: .failure(
            OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
                found: [.init(sourceLabel: "Chrome", email: "other@example.com")])))

        let imported = await importTask.value
        #expect(imported == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardCookieImportStatus == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `settings refresh waits for forced enrichment instead of being dropped`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-settings-waits-for-tail")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        var providerInteractions: [ProviderInteraction] = []
        var didObserveWait = false
        store._test_providerRefreshOverride = { _ in
            providerInteractions.append(ProviderInteractionContext.current)
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
        store._test_forcedRefreshEnrichmentWaitObserver = {
            didObserveWait = true
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_forcedRefreshEnrichmentWaitObserver = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        let didStartTokenTail = await tokenGate.waitUntilStarted(count: 1)
        #expect(didStartTokenTail)
        guard didStartTokenTail else {
            await self.cancelForcedEnrichmentWork(store: store)
            return
        }
        settings.costUsageEnabled = false

        let completion = RefreshCompletionProbe()
        var settingsRefreshes: [Task<Void, Never>] = []
        for expectedGeneration in 1...3 {
            let task = Task { @MainActor in
                await store.refreshForSettingsChange()
                await completion.markCompleted()
            }
            settingsRefreshes.append(task)
            for _ in 0..<100 where store.requiredRefreshRequestGeneration < expectedGeneration {
                await Task.yield()
            }
            #expect(store.requiredRefreshRequestGeneration == expectedGeneration)
        }
        for _ in 0..<100 where !didObserveWait {
            await Task.yield()
        }

        #expect(didObserveWait)
        #expect(providerInteractions == [.background])
        #expect(await completion.isCompleted == false)

        await tokenGate.resumeNext()
        for task in settingsRefreshes {
            await task.value
        }

        #expect(providerInteractions == [.background, .background])
        #expect(await completion.isCompleted)
        #expect(store.requiredRefreshCompletedGeneration == 3)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `required post-action refresh waits for forced enrichment`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-required-refresh-waits-for-tail")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        var providerInteractions: [ProviderInteraction] = []
        var didObserveWait = false
        store._test_providerRefreshOverride = { _ in
            providerInteractions.append(ProviderInteractionContext.current)
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
        store._test_forcedRefreshEnrichmentWaitObserver = {
            didObserveWait = true
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_forcedRefreshEnrichmentWaitObserver = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        let didStartTokenTail = await tokenGate.waitUntilStarted(count: 1)
        #expect(didStartTokenTail)
        guard didStartTokenTail else {
            await self.cancelForcedEnrichmentWork(store: store)
            return
        }
        settings.costUsageEnabled = false

        let completion = RefreshCompletionProbe()
        let requiredRefresh = Task { @MainActor in
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.refresh()
            }
            await completion.markCompleted()
        }
        for _ in 0..<100 where !didObserveWait {
            await Task.yield()
        }

        #expect(didObserveWait)
        #expect(providerInteractions == [.background])
        #expect(await completion.isCompleted == false)

        await tokenGate.resumeNext()
        await requiredRefresh.value

        #expect(providerInteractions == [.background, .userInitiated])
        #expect(await completion.isCompleted)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `startup retry waits for forced enrichment and completes its retry pass`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-startup-retry-waits-for-tail")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let retrySleep = ForcedRefreshRetrySleepGate()
        let tokenGate = BlockingForcedTokenRefresh()
        var statusAttempts = 0
        var didObserveWait = false
        store._test_providerRefreshOverride = { _ in }
        store._test_providerStatusFetchOverride = { _ in
            statusAttempts += 1
            if statusAttempts == 1 {
                throw URLError(.cannotFindHost)
            }
            return ProviderStatus(indicator: .none, description: "Operational", updatedAt: Date())
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
        store._test_startupConnectivityRetrySleepOverride = { delay in
            try await retrySleep.sleep(delay)
        }
        store._test_forcedRefreshEnrichmentWaitObserver = {
            didObserveWait = true
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_providerStatusFetchOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_startupConnectivityRetrySleepOverride = nil
            store._test_forcedRefreshEnrichmentWaitObserver = nil
            store.startupConnectivityRetryTask?.cancel()
            store.startupConnectivityRetryTask = nil
        }

        await store.refresh()
        let didStartRetrySleep = await retrySleep.waitUntilSleeping()
        #expect(didStartRetrySleep)
        guard didStartRetrySleep else {
            store.startupConnectivityRetryTask?.cancel()
            return
        }
        let retryTask = try #require(store.startupConnectivityRetryTask)

        settings.costUsageEnabled = true
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refresh(enrichmentMode: .forcedBackground)
        }
        let didStartTokenTail = await tokenGate.waitUntilStarted(count: 1)
        #expect(didStartTokenTail)
        guard didStartTokenTail else {
            await self.cancelForcedEnrichmentWork(store: store)
            retryTask.cancel()
            await retryTask.value
            return
        }
        settings.costUsageEnabled = false

        await retrySleep.resume()
        for _ in 0..<100 where !didObserveWait {
            await Task.yield()
        }

        #expect(didObserveWait)
        #expect(statusAttempts == 2)

        await tokenGate.resumeNext()
        await retryTask.value

        #expect(statusAttempts == 3)
        #expect(store.statuses[.codex]?.indicator == ProviderStatusIndicator.none)
        #expect(store.startupConnectivityRetryTask == nil)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }
}

extension CodexBackgroundRefreshCoalescingTests {
    @Test
    func `forced enrichment keeps one active and the latest contextual follow-up`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-enrichment-latest")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let gate = BlockingForcedTokenRefresh()
        let deniedAt = Date()
        var providerRefreshCount = 0
        store._test_providerRefreshOverride = { _ in
            providerRefreshCount += 1
        }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        store._test_tokenUsageRefreshOverride = { provider, force in
            let retryAllowed = BrowserCookieAccessGate.shouldAttempt(
                .arc,
                now: deniedAt.addingTimeInterval(1))
            await gate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: retryAllowed)
        }
        defer { store._test_tokenUsageRefreshOverride = nil }

        await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.arc]) {
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                let firstRefresh = Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await store.refresh(enrichmentMode: .forcedBackground)
                    }
                }
                let didStartFirstTail = await gate.waitUntilStarted(count: 1)
                #expect(didStartFirstTail)
                guard didStartFirstTail else {
                    firstRefresh.cancel()
                    await self.cancelForcedEnrichmentWork(store: store)
                    await firstRefresh.value
                    return
                }
                await firstRefresh.value

                await store.refresh(enrichmentMode: .automatic)
                #expect(providerRefreshCount == 1)

                await ProviderInteractionContext.$current.withValue(.background) {
                    await store.refresh(enrichmentMode: .forcedBackground)
                }
                let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in .allowed }
                await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(preflightOverride) {
                    await BrowserCookieAccessGate.withExplicitRetry {
                        await ProviderInteractionContext.$current.withValue(.userInitiated) {
                            await store.refresh(enrichmentMode: .forcedBackground)
                        }
                    }
                }

                #expect(store.forcedRefreshEnrichmentTask != nil)
                #expect(store.pendingForcedRefreshEnrichmentTask != nil)
                #expect(store.hasForcedRefreshEnrichmentInFlight)

                await gate.resumeNext()
                let didStartLatestTail = await gate.waitUntilStarted(count: 2)
                #expect(didStartLatestTail)
                guard didStartLatestTail else {
                    await self.cancelForcedEnrichmentWork(store: store)
                    return
                }

                let calls = await gate.recordedCalls()
                #expect(calls.map(\.provider) == [.codex, .codex])
                #expect(calls.map(\.force) == [true, true])
                #expect(calls.map(\.interaction) == [.background, .userInitiated])
                #expect(calls.map(\.refreshPhase) == [.startup, .regular])
                #expect(calls.map(\.browserRetryAllowed) == [false, true])

                await gate.resumeNext()
                await store.awaitForcedRefreshEnrichment()
                #expect(!store.hasForcedRefreshEnrichmentInFlight)
                #expect(store.forcedRefreshEnrichmentTask == nil)
                #expect(store.pendingForcedRefreshEnrichmentTask == nil)
            }
        }
    }

    @Test
    func `forced background login failure reconciles provider and credits once`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-login-reconciliation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        var providerRefreshes = 0
        var creditsRefreshes = 0
        var dashboardLoads = 0
        store._test_providerRefreshOverride = { provider in
            #expect(provider == .codex)
            providerRefreshes += 1
        }
        store._test_codexCreditsLoaderOverride = {
            creditsRefreshes += 1
            return CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            dashboardLoads += 1
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Fixture",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
            store._test_openAIDashboardCookieImportOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        await store.awaitForcedRefreshEnrichment()

        #expect(dashboardLoads == 2)
        #expect(providerRefreshes == 2)
        #expect(creditsRefreshes == 2)
        #expect(store.openAIDashboardRequiresLogin)
    }

    @Test
    func `older login reconciliation yields to an already pending forced tail`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-login-pending-generation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let tokenGate = BlockingForcedTokenRefresh()
        let dashboardLoader = LoginThenSuccessDashboardLoader(email: managedAccount.email)
        var providerInteractions: [ProviderInteraction] = []
        var creditsInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in
            providerInteractions.append(ProviderInteractionContext.current)
        }
        store._test_codexCreditsLoaderOverride = {
            creditsInteractions.append(ProviderInteractionContext.current)
            return CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await dashboardLoader.load()
        }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Fixture",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
            store._test_openAIDashboardCookieImportOverride = nil
        }

        await ProviderInteractionContext.$current.withValue(.background) {
            await store.refresh(enrichmentMode: .forcedBackground)
        }
        let didStartOlderTail = await tokenGate.waitUntilStarted(count: 1)
        #expect(didStartOlderTail)
        guard didStartOlderTail else {
            let activeTask = store.forcedRefreshEnrichmentTask
            store.cancelForcedRefreshEnrichment()
            await activeTask?.value
            return
        }

        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refresh(enrichmentMode: .forcedBackground)
        }
        #expect(store.pendingForcedRefreshEnrichmentTask != nil)

        await tokenGate.resumeNext()
        let didStartNewerTail = await tokenGate.waitUntilStarted(count: 2)
        #expect(didStartNewerTail)
        guard didStartNewerTail else {
            let tasks = [
                store.forcedRefreshEnrichmentTask,
                store.pendingForcedRefreshEnrichmentTask,
            ].compactMap(\.self)
            store.cancelForcedRefreshEnrichment()
            for task in tasks {
                await task.value
            }
            return
        }

        #expect(await dashboardLoader.callCount() == 2)
        #expect(store.openAIDashboardRequiresLogin)
        #expect(providerInteractions == [.background, .userInitiated])
        #expect(creditsInteractions == [.background, .userInitiated])

        await tokenGate.resumeNext()
        await store.awaitForcedRefreshEnrichment()

        #expect(await dashboardLoader.callCount() == 3)
        #expect(!store.openAIDashboardRequiresLogin)
        #expect(providerInteractions.count == 2)
        #expect(creditsInteractions.count == 2)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `older login reconciliation does not replace newer forced provider work`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-login-inflight-generation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let providerGate = BlockingSecondProviderRefresh()
        let tokenGate = BlockingForcedTokenRefresh()
        let dashboardLoader = LoginThenSuccessDashboardLoader(email: managedAccount.email)
        var creditsInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in
            await providerGate.run(interaction: ProviderInteractionContext.current)
        }
        store._test_codexCreditsLoaderOverride = {
            creditsInteractions.append(ProviderInteractionContext.current)
            return CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenGate.run(
                provider: provider,
                force: force,
                interaction: ProviderInteractionContext.current,
                refreshPhase: ProviderRefreshContext.current,
                browserRetryAllowed: false)
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await dashboardLoader.load()
        }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Fixture",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
            store._test_openAIDashboardCookieImportOverride = nil
        }

        await ProviderInteractionContext.$current.withValue(.background) {
            await store.refresh(enrichmentMode: .forcedBackground)
        }
        let didStartOlderTail = await tokenGate.waitUntilStarted(count: 1)
        #expect(didStartOlderTail)
        guard didStartOlderTail else {
            let activeTask = store.forcedRefreshEnrichmentTask
            store.cancelForcedRefreshEnrichment()
            await activeTask?.value
            return
        }
        let olderTail = try #require(store.forcedRefreshEnrichmentTask)

        let newerRefresh = Task { @MainActor in
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.refresh(enrichmentMode: .forcedBackground)
            }
        }
        let didStartNewerProviderRefresh = await providerGate.waitUntilStarted(count: 2)
        #expect(didStartNewerProviderRefresh)
        guard didStartNewerProviderRefresh else {
            newerRefresh.cancel()
            await providerGate.releaseBlockedCall()
            store.cancelForcedRefreshEnrichment()
            await tokenGate.resumeNext()
            await newerRefresh.value
            return
        }

        let olderTailCompletion = RefreshCompletionProbe()
        let olderTailWaiter = Task {
            await olderTail.value
            await olderTailCompletion.markCompleted()
        }
        await tokenGate.resumeNext()
        let didCompleteOlderTail = await olderTailCompletion.waitUntilCompleted()
        #expect(didCompleteOlderTail)
        guard didCompleteOlderTail else {
            await providerGate.releaseBlockedCall()
            await newerRefresh.value
            let tasks = [
                store.forcedRefreshEnrichmentTask,
                store.pendingForcedRefreshEnrichmentTask,
            ].compactMap(\.self)
            store.cancelForcedRefreshEnrichment()
            for task in tasks {
                await task.value
            }
            await olderTailWaiter.value
            return
        }
        await olderTailWaiter.value

        #expect(await dashboardLoader.callCount() == 2)
        #expect(store.openAIDashboardRequiresLogin)
        #expect(await providerGate.wasBlockedCallCancelled() == false)
        #expect(await providerGate.recordedInteractions() == [.background, .userInitiated])
        #expect(creditsInteractions == [.background])

        await providerGate.releaseBlockedCall()
        await newerRefresh.value
        let didStartNewerTail = await tokenGate.waitUntilStarted(count: 2)
        #expect(didStartNewerTail)
        guard didStartNewerTail else {
            let tasks = [
                store.forcedRefreshEnrichmentTask,
                store.pendingForcedRefreshEnrichmentTask,
            ].compactMap(\.self)
            store.cancelForcedRefreshEnrichment()
            for task in tasks {
                await task.value
            }
            return
        }
        await tokenGate.resumeNext()
        await store.awaitForcedRefreshEnrichment()

        #expect(await dashboardLoader.callCount() == 3)
        #expect(!store.openAIDashboardRequiresLogin)
        #expect(await providerGate.wasBlockedCallCancelled() == false)
        #expect(await providerGate.recordedInteractions() == [.background, .userInitiated])
        #expect(creditsInteractions == [.background, .userInitiated])
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `cancelling forced enrichment cancels its real dashboard child`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-dashboard-child-cancellation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let dashboardLoader = CancellationAwareOpenAIDashboardLoader(email: managedAccount.email)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await dashboardLoader.load()
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_openAIDashboardLoaderOverride = nil
        }

        await store.refresh(enrichmentMode: .forcedBackground)
        let capturedEnrichmentTask = store.forcedRefreshEnrichmentTask
        let didStartDashboardRefresh = await dashboardLoader.waitUntilStarted()
        #expect(didStartDashboardRefresh)
        guard didStartDashboardRefresh else {
            store.cancelForcedRefreshEnrichment()
            await capturedEnrichmentTask?.value
            return
        }
        let enrichmentTask = try #require(capturedEnrichmentTask)
        let dashboardTask = try #require(store.openAIDashboardRefreshTask)

        store.cancelForcedRefreshEnrichment()
        await enrichmentTask.value
        await dashboardTask.value

        #expect(await dashboardLoader.wasCancelled())
        #expect(dashboardTask.isCancelled)
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(!store.openAIDashboardRequiresLogin)
        #expect(store.openAIDashboardRefreshTask == nil)
        #expect(store.openAIDashboardBackgroundRefreshTask == nil)
        #expect(store.forcedRefreshEnrichmentTask == nil)
        #expect(store.pendingForcedRefreshEnrichmentTask == nil)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }

    @Test
    func `forced background enrichment runs dashboard under battery saver with user context`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-forced-dashboard-battery")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebBatterySaverEnabled = true
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        var dashboardInteractions: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            dashboardInteractions.append(ProviderInteractionContext.current)
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
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await BrowserCookieAccessGate.withExplicitRetry {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.refresh(enrichmentMode: .forcedBackground)
            }
        }
        await store.awaitForcedRefreshEnrichment()

        #expect(dashboardInteractions == [.userInitiated])
        #expect(store.openAIDashboard?.signedInEmail == managedAccount.email)
        #expect(!store.hasForcedRefreshEnrichmentInFlight)
    }
}

extension CodexBackgroundRefreshCoalescingTests {
    private func cancelForcedEnrichmentWork(store: UsageStore) async {
        let tasks = [
            store.forcedRefreshEnrichmentTask,
            store.pendingForcedRefreshEnrichmentTask,
        ].compactMap(\.self)
        store.cancelForcedRefreshEnrichment()
        for task in tasks {
            await task.value
        }
    }

    private func cancelCreditsWork(
        store: UsageStore,
        blocker: BlockingCreditsLoader,
        tasks: [Task<Void, Never>]) async
    {
        let creditsTask = store.creditsRefreshTask
        tasks.forEach { $0.cancel() }
        creditsTask?.cancel()
        await blocker.cancelAll()
        for task in tasks {
            await task.value
        }
        await creditsTask?.value
    }

    private func cancelDashboardWork(
        store: UsageStore,
        blocker: BlockingManagedOpenAIDashboardLoader,
        tasks: [Task<Void, Never>]) async
    {
        let dashboardTasks = [
            store.openAIDashboardBackgroundRefreshTask,
            store.openAIDashboardRefreshTask,
        ].compactMap(\.self)
        tasks.forEach { $0.cancel() }
        store.invalidateOpenAIDashboardRefreshTask()
        await blocker.cancelAll()
        for task in tasks {
            await task.value
        }
        for task in dashboardTasks {
            await task.value
        }
    }

    func makeSettingsStore(suite: String) throws -> SettingsStore {
        let settings = testSettingsStore(suiteName: suite)
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.providerDetectionCompleted = true
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        return settings
    }

    func makeStore(settings: SettingsStore) -> UsageStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    static func installManagedAccount(
        email: String,
        settings: SettingsStore) throws -> ManagedCodexAccount
    {
        let account = try Self.makeManagedAccount(email: email)
        settings._test_activeManagedCodexAccount = account
        settings.codexActiveSource = .managedAccount(id: account.id)
        return account
    }

    private static func makeManagedAccount(email: String) throws -> ManagedCodexAccount {
        let managedHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHomeURL,
            email: email,
            plan: "Pro")
        return ManagedCodexAccount(
            id: UUID(),
            email: email,
            managedHomePath: managedHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
            ],
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}

actor BlockingForcedTokenRefresh {
    struct Call: Sendable {
        let provider: UsageProvider
        let force: Bool
        let interaction: ProviderInteraction
        let refreshPhase: ProviderRefreshPhase
        let browserRetryAllowed: Bool
    }

    private var calls: [Call] = []
    private var continuations: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    func run(
        provider: UsageProvider,
        force: Bool,
        interaction: ProviderInteraction,
        refreshPhase: ProviderRefreshPhase,
        browserRetryAllowed: Bool) async
    {
        let id = UUID()
        self.calls.append(Call(
            provider: provider,
            force: force,
            interaction: interaction,
            refreshPhase: refreshPhase,
            browserRetryAllowed: browserRetryAllowed))
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

    @discardableResult
    func waitUntilStarted(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.calls.count < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func resumeNext() {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().continuation.resume()
    }

    func recordedCalls() -> [Call] {
        self.calls
    }

    private func cancel(id: UUID) {
        guard let index = self.continuations.firstIndex(where: { $0.id == id }) else { return }
        self.continuations.remove(at: index).continuation.resume()
    }
}

private actor LoginThenSuccessDashboardLoader {
    private let email: String
    private var calls = 0

    init(email: String) {
        self.email = email
    }

    func load() throws -> OpenAIDashboardSnapshot {
        self.calls += 1
        if self.calls <= 2 {
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        return OpenAIDashboardSnapshot(
            signedInEmail: self.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())
    }

    func callCount() -> Int {
        self.calls
    }
}

private actor ForcedRefreshRetrySleepGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func sleep(_ delay: TimeInterval) async throws {
        #expect(delay == 15)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if self.cancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    @discardableResult
    func waitUntilSleeping(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.continuation == nil {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }

    private func cancel() {
        self.cancelled = true
        self.continuation?.resume(throwing: CancellationError())
        self.continuation = nil
    }
}

private actor BlockingSecondProviderRefresh {
    private var interactions: [ProviderInteraction] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedCallCancelled = false
    private var blockedCallReleased = false

    func run(interaction: ProviderInteraction) async {
        self.interactions.append(interaction)
        guard self.interactions.count == 2 else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.blockedCallCancelled || self.blockedCallReleased || Task.isCancelled {
                    if Task.isCancelled {
                        self.blockedCallCancelled = true
                    }
                    continuation.resume()
                } else {
                    self.blockedContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelBlockedCall() }
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

    func releaseBlockedCall() {
        self.blockedCallReleased = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
    }

    func wasBlockedCallCancelled() -> Bool {
        self.blockedCallCancelled
    }

    func recordedInteractions() -> [ProviderInteraction] {
        self.interactions
    }

    private func cancelBlockedCall() {
        self.blockedCallCancelled = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
    }
}

private actor CancellationAwareOpenAIDashboardLoader {
    private let email: String
    private var started = false
    private var cancelled = false

    init(email: String) {
        self.email = email
    }

    func load() async throws -> OpenAIDashboardSnapshot {
        self.started = true

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            self.cancelled = true
            throw CancellationError()
        }

        return OpenAIDashboardSnapshot(
            signedInEmail: self.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !self.started {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func wasCancelled() -> Bool {
        self.cancelled
    }
}

private actor BlockingOpenAIDashboardCookieImport {
    private typealias ImportResult = OpenAIDashboardBrowserCookieImporter.ImportResult
    private typealias ResultContinuation = CheckedContinuation<Result<ImportResult, Error>, Never>

    private var continuations: [(id: UUID, continuation: ResultContinuation)] = []
    private var started = 0
    private var cancellations = 0
    private var cancelledIDs: Set<UUID> = []
    private var rejectsNewCalls = false

    func awaitResult() async throws -> OpenAIDashboardBrowserCookieImporter.ImportResult {
        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: ResultContinuation) in
                if self.rejectsNewCalls || Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else {
                    self.continuations.append((id: id, continuation: continuation))
                    self.started += 1
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        return try result.get()
    }

    func waitUntilStarted(count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.started < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func waitUntilCancellationCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.cancellations < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func resumeNext(with result: Result<OpenAIDashboardBrowserCookieImporter.ImportResult, Error>) {
        guard !self.continuations.isEmpty else { return }
        let record = self.continuations.removeFirst()
        self.cancelledIDs.remove(record.id)
        record.continuation.resume(returning: result)
    }

    func cancelAll() {
        self.rejectsNewCalls = true
        let continuations = self.continuations
        self.continuations.removeAll()
        self.cancelledIDs.removeAll()
        continuations.forEach { $0.continuation.resume(returning: .failure(CancellationError())) }
    }

    private func cancel(id: UUID) {
        guard self.continuations.contains(where: { $0.id == id }), self.cancelledIDs.insert(id).inserted else { return }
        self.cancellations += 1
    }
}
