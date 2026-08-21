import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `account transition starts nonforced token refresh then one forced fallback for selected profile`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-profile-fallback")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-profile-a"
        let profileB = "/tmp/codex-profile-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var requests: [(force: Bool, homePath: String?)] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            #expect(provider == .codex)
            requests.append((force, store.tokenCostScope(for: .codex).codexHomePath))
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let priorScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        await store.refreshCodexAccountScopedState(
            allowDisabled: true,
            priorTokenScopeSignature: priorScope)

        #expect(requests.map(\.force) == [false, true])
        #expect(requests.map(\.homePath) == [profileB, profileB])
    }

    @Test
    func `current confirmed empty token publication stops forced fallback`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-confirmed-empty")
        settings.costUsageEnabled = true
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var requests: [Bool] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            requests.append(force)
            if provider == .codex, !force {
                store.publishConfirmedEmptyTokenSnapshot(for: .codex)
            }
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refreshCodexAccountScopedState(allowDisabled: true)

        #expect(requests == [false])
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) != nil)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == nil)
    }

    @Test
    func `token lane skips cost off and disabled codex`() async throws {
        let costOffSettings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-cost-off")
        costOffSettings.costUsageEnabled = false
        costOffSettings.codexLocalSessionCostLedgerEnabled = false
        let costOffStore = self.makeUsageStore(settings: costOffSettings)
        costOffStore._test_providerRefreshOverride = { _ in }
        costOffStore._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var costOffRequests = 0
        costOffStore._test_tokenUsageRefreshOverride = { _, _ in costOffRequests += 1 }
        await costOffStore.refreshCodexAccountScopedState(allowDisabled: true)
        #expect(costOffRequests == 0)

        let disabledSettings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-disabled")
        disabledSettings.costUsageEnabled = true
        let codexMetadata = try #require(ProviderRegistry.shared.metadata[.codex])
        disabledSettings.setProviderEnabled(
            provider: .codex,
            metadata: codexMetadata,
            enabled: false)
        let disabledStore = self.makeUsageStore(settings: disabledSettings)
        disabledStore._test_providerRefreshOverride = { _ in }
        disabledStore._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var disabledRequests = 0
        disabledStore._test_tokenUsageRefreshOverride = { _, _ in disabledRequests += 1 }
        await disabledStore.refreshCodexAccountScopedState(allowDisabled: true)
        #expect(disabledRequests == 0)
    }

    @Test
    func `old aba transition cannot force fallback and newest transition can`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-aba")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-aba-a"
        let profileB = "/tmp/codex-aba-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let firstStarted = CodexAccountScopedRefreshSignal()
        let releaseFirst = CodexAccountScopedRefreshSignal()
        var requests: [(Bool, String?)] = []
        store._test_tokenUsageRefreshOverride = { _, force in
            let homePath = store.tokenCostScope(for: .codex).codexHomePath
            requests.append((force, homePath))
            if requests.count == 1 {
                firstStarted.signal()
                await releaseFirst.wait()
            }
        }
        defer {
            releaseFirst.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let scopeA = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        let oldTransition = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: scopeA)
        }
        #expect(await firstStarted.waitUntilSignaled())

        let scopeB = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileA)
        releaseFirst.signal()
        await oldTransition.value
        #expect(requests.map(\.0) == [false])

        await store.refreshCodexAccountScopedState(
            allowDisabled: true,
            priorTokenScopeSignature: scopeB)
        #expect(requests.map(\.0) == [false, false, true])
        #expect(requests.map(\.1) == [profileB, profileA, profileA])
    }

    @Test
    func `cancelling account refresh cancels token wait without fallback`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-cancel")
        settings.costUsageEnabled = true
        settings.codexActiveSource = .profileHome(path: "/tmp/codex-cancel")
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let started = CodexAccountScopedRefreshSignal()
        var requests: [Bool] = []
        var observedCancellation = false
        store._test_tokenUsageRefreshOverride = { _, force in
            requests.append(force)
            started.signal()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                observedCancellation = true
            } catch {}
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let refreshTask = Task { await store.refreshCodexAccountScopedState(allowDisabled: true) }
        #expect(await started.waitUntilSignaled())
        refreshTask.cancel()
        await refreshTask.value

        #expect(requests == [false])
        #expect(observedCancellation)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
    }

    @Test
    func `physical account refresh retries cancelled profile scans and publishes final a across aba`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-physical-aba")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-physical-aba-a"
        let profileB = "/tmp/codex-physical-aba-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let loader = PhysicalTokenSnapshotLoaderGate()
        var sequenceStartCount = 0
        store._test_tokenRefreshSequenceStartBarrier = { sequenceStartCount += 1 }
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            return try await loader.load(homePath: homePath)
        }
        defer {
            loader.cleanup()
            store.tokenRefreshSequenceTask?.cancel()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenRefreshSequenceStartBarrier = nil
            store._test_tokenUsageSnapshotLoaderOverride = nil
        }

        let initialA = Task { await store.refreshCodexAccountScopedState(allowDisabled: true) }
        #expect(await loader.waitForRequestCount(1))
        #expect(sequenceStartCount == 1)
        #expect(loader.homePaths() == [profileA])

        let priorAScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        initialA.cancel()
        try loader.releaseRequest(at: 0, with: .failure(CancellationError()))
        #expect(await loader.waitForRequestCount(2))
        #expect(sequenceStartCount == 2)
        #expect(loader.homePaths() == [profileA, profileB])
        await initialA.value

        let profileBRefreshStarted = CodexAccountScopedRefreshSignal()
        let profileBRefresh = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: priorAScope,
                phaseDidChange: { phase in
                    if phase == .usage { profileBRefreshStarted.signal() }
                })
        }
        #expect(await profileBRefreshStarted.waitUntilSignaled())
        let priorBScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileA)
        try loader.releaseRequest(at: 1, with: .failure(CancellationError()))
        #expect(await loader.waitForRequestCount(3))
        #expect(sequenceStartCount == 3)
        #expect(loader.homePaths() == [profileA, profileB, profileA])
        await profileBRefresh.value

        let finalARefresh = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: priorBScope)
        }
        try loader.releaseRequest(at: 2, with: .success(self.tokenSnapshot(cost: 3)))
        await finalARefresh.value

        #expect(store.tokenRefreshRetryProviders.isEmpty)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 3)
        let publication = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex))
        #expect(publication.snapshot?.last30DaysCostUSD == 3)
        let storedPublication = try #require(store.tokenSnapshotPublications[.codex])
        #expect(storedPublication.scopeSignature == store.tokenSnapshotScopeSignature(for: .codex))
    }

    @Test
    func `current profile loader failure preserves incompatible raw snapshot without current publication`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-profile-failure")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-profile-failure-a"
        let profileB = "/tmp/codex-profile-failure-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        let rawA = self.tokenSnapshot(cost: 1)
        store._setTokenSnapshotForTesting(rawA, provider: .codex)
        let publicationA = store.tokenSnapshotPublications[.codex]
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == profileB)
            throw TestRefreshError(message: "profile B scan failed")
        }
        defer { store._test_tokenUsageSnapshotLoaderOverride = nil }

        settings.codexActiveSource = .profileHome(path: profileB)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)

        await store.refreshTokenUsage(.codex, force: true)

        #expect(store.tokenSnapshot(for: .codex) == rawA)
        #expect(store.tokenSnapshotPublications[.codex] == publicationA)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
    }

    @Test
    func `cancelling transition after codex lane cancels exact shared claude lane`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-shared-cancel")
        settings.costUsageEnabled = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude || provider == .codex)
        }
        settings.setProviderOrder([.codex, .claude])
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let claudeLaneStarted = CodexAccountScopedRefreshSignal()
        var calls: [UsageProvider] = []
        var codexLaneFinished = false
        var cancelledProvider: UsageProvider?
        store._test_tokenUsageRefreshOverride = { provider, _ in
            calls.append(provider)
            if provider == .codex {
                codexLaneFinished = true
                store.publishConfirmedEmptyTokenSnapshot(for: .codex)
                return
            }
            #expect(provider == .claude)
            claudeLaneStarted.signal()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                cancelledProvider = provider
            } catch {}
        }
        defer {
            store.tokenRefreshSequenceTask?.cancel()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        store.scheduleTokenRefreshForTesting()
        #expect(await claudeLaneStarted.waitUntilSignaled())
        #expect(codexLaneFinished)
        #expect(calls == [.codex, .claude])
        #expect(store.tokenRefreshSequenceProvider == UsageProvider.claude.instanceID)
        let sharedToken = try #require(store.tokenRefreshSequenceToken)
        let transition = Task { await store.refreshCodexAccountScopedState(allowDisabled: true) }
        await Task.yield()
        #expect(store.tokenRefreshSequenceToken == sharedToken)

        transition.cancel()
        await transition.value
        await store.tokenRefreshSequenceTask?.value

        #expect(calls == [.codex, .claude])
        #expect(cancelledProvider == .claude)
        #expect(store.tokenRefreshSequenceTask == nil)
    }

    @Test
    func `ambient publication compatibility does not relax in flight completion guard`() {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-ambient-strict")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = true
        let profileA = "/tmp/codex-ambient-strict-a"
        let profileB = "/tmp/codex-ambient-strict-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        let snapshot = self.tokenSnapshot(cost: 1)
        store._setTokenSnapshotForTesting(snapshot, provider: .codex)
        let publicationRevision = store.providerPublicationRevision(for: .codex)
        let providerConfigRevision = settings.providerConfigRevision(for: .codex)
        let historyDays = settings.costUsageHistoryDays
        let costScopeSignature = store.tokenSnapshotScopeSignature(for: .codex)

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == snapshot)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationRevision: publicationRevision,
            providerConfigRevision: providerConfigRevision,
            historyDays: historyDays,
            costScopeSignature: costScopeSignature))
    }

    @Test
    func `token errors clear only when activation changes full token scope`() {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-errors")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-errors-a"
        let profileB = "/tmp/codex-errors-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store.tokenErrors[.codex] = "profile A failed"
        _ = store.tokenFailureGates[.codex]?.shouldSurfaceError(onFailureWithPriorData: false)
        let profileAScope = store.tokenSnapshotScopeSignature(for: .codex)

        settings.codexActiveSource = .profileHome(path: profileB)
        _ = store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileAScope)
        #expect(store.tokenErrors[.codex] == nil)
        #expect(store.tokenFailureGates[.codex]?.streak == 0)

        settings.codexLocalSessionCostLedgerEnabled = true
        store.tokenErrors[.codex] = "ambient failed"
        _ = store.tokenFailureGates[.codex]?.shouldSurfaceError(onFailureWithPriorData: false)
        let ambientScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileA)
        _ = store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: ambientScope)
        #expect(store.tokenErrors[.codex] == "ambient failed")
        #expect(store.tokenFailureGates[.codex]?.streak == 1)
    }

    @Test
    func `first profile scope change invalidates while duplicate and ambient selections do not`() {
        let profileA = "/tmp/codex-first-invalidation-a"
        let profileB = "/tmp/codex-first-invalidation-b"
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-first-invalidation")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "profile-a@example.com", usedPercent: 12),
            provider: .codex)
        let profileAScope = store.tokenSnapshotScopeSignature(for: .codex)

        #expect(store.lastCodexAccountScopedRefreshGuard == nil)
        settings.codexActiveSource = .profileHome(path: profileB)
        #expect(store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileAScope))
        #expect(store.snapshots[.codex] == nil)

        let profileBScope = store.tokenSnapshotScopeSignature(for: .codex)
        #expect(!store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileBScope))

        let ambientSettings = self.makeSettingsStore(
            suite: "CodexAccountScopedTokenRefreshTests-first-invalidation-ambient")
        ambientSettings.costUsageEnabled = true
        ambientSettings.codexLocalSessionCostLedgerEnabled = true
        ambientSettings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let ambientStore = self.makeUsageStore(settings: ambientSettings)
        let ambientScope = ambientStore.tokenSnapshotScopeSignature(for: .codex)
        ambientSettings.codexActiveSource = .profileHome(path: profileB)

        #expect(ambientStore.lastCodexAccountScopedRefreshGuard == nil)
        #expect(!ambientStore.prepareCodexAccountScopedRefreshIfNeeded(
            priorTokenScopeSignature: ambientScope))
    }

    @Test
    func `settings card hides prior profile cost while selected profile scan is blocked`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-settings-card")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-settings-card-a"
        let profileB = "/tmp/codex-settings-card-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._setTokenSnapshotForTesting(self.tokenSnapshot(cost: 1), provider: .codex)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let scanStarted = CodexAccountScopedRefreshSignal()
        let releaseScan = CodexAccountScopedRefreshSignal()
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == profileB)
            scanStarted.signal()
            await releaseScan.wait()
            return self.tokenSnapshot(cost: 2)
        }
        defer {
            releaseScan.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageSnapshotLoaderOverride = nil
        }

        let pane = ProvidersPane(settings: settings, store: store)
        #expect(pane.menuCardModel(for: .codex).tokenUsage != nil)
        let priorScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        let refresh = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: priorScope)
        }
        #expect(await scanStarted.waitUntilSignaled())

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(pane.menuCardModel(for: .codex).tokenUsage == nil)

        releaseScan.signal()
        await refresh.value
        #expect(pane.menuCardModel(for: .codex).tokenUsage?.sessionLine.contains("20") == true)
    }

    @Test
    func `managed switch rebuilds tracked popup before and after successful scoped token refresh`() async throws {
        try await self.assertTrackedPopupTokenPresentation(outcome: .success)
    }

    @Test
    func `tracked popup keeps old cost absent after selected profile token failure`() async throws {
        try await self.assertTrackedPopupTokenPresentation(outcome: .failure)
    }

    @Test
    func `tracked popup keeps old cost absent after selected profile token cancellation`() async throws {
        try await self.assertTrackedPopupTokenPresentation(outcome: .cancellation)
    }

    private func assertTrackedPopupTokenPresentation(outcome: TrackedPopupTokenRefreshOutcome) async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-popup")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.codexLocalSessionCostLedgerEnabled = false
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let managedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managedHomeA = managedRoot.appendingPathComponent("managed-a", isDirectory: true)
        let managedHomeB = managedRoot.appendingPathComponent("managed-b", isDirectory: true)
        let managedStoreURL = managedRoot.appendingPathComponent("accounts.json")
        let missingLiveHome = managedRoot.appendingPathComponent("missing-live", isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: managedHomeA, email: "managed-a@example.com", plan: "pro")
        try Self.writeCodexAuthFile(homeURL: managedHomeB, email: "managed-b@example.com", plan: "pro")
        let managedAccountA = ManagedCodexAccount(
            id: UUID(),
            email: "managed-a@example.com",
            managedHomePath: managedHomeA.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedAccountB = ManagedCodexAccount(
            id: UUID(),
            email: "managed-b@example.com",
            managedHomePath: managedHomeB.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccountA, managedAccountB]))
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.codexActiveSource = .managedAccount(id: managedAccountA.id)
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: managedRoot)
        }

        let visibleAccounts = settings.codexVisibleAccountProjection.visibleAccounts
        #expect(visibleAccounts.count == 2)
        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccountA.id))
        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(300),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setTokenSnapshotForTesting(self.tokenSnapshot(cost: 1), provider: .codex)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let scanStarted = CodexAccountScopedRefreshSignal()
        let releaseScan = CodexAccountScopedRefreshSignal()
        var scanCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == managedHomeB.path)
            scanCount += 1
            if scanCount == 1 {
                scanStarted.signal()
                await releaseScan.wait()
            }
            return try self.trackedPopupTokenSnapshot(outcome: outcome)
        }
        defer {
            releaseScan.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageSnapshotLoaderOverride = nil
        }
        _ = settings.codexVisibleAccountProjection

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: true,
            menuRefreshEnabled: true,
            observeProviderConfigNotifications: false)
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = 0
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.lastCodexAccountScopedRefreshGuard == nil)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let switcher = try #require(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
        let managedBVisibleAccount = try #require(visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: managedAccountB.id)
        })
        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD == 1)
        #expect(self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            if rebuiltMenu === menu { rebuildCount += 1 }
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        switcher._test_selectAccount(id: managedBVisibleAccount.id)
        #expect(await scanStarted.waitUntilSignaled())

        let rebuildDeadline = ContinuousClock.now + .seconds(5)
        while rebuildCount == 0 || self.menuItem(in: menu, id: "menuCardCost") != nil,
              ContinuousClock.now < rebuildDeadline
        {
            await Task.yield()
        }
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountB.id))
        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccountB.id))
        #expect(rebuildCount > 0)
        #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)
        #expect(!self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))

        releaseScan.signal()
        let completionDeadline = ContinuousClock.now + .seconds(5)
        switch outcome {
        case .success:
            while self.menuItem(in: menu, id: "menuCardCost") == nil ||
                store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD != 2,
                ContinuousClock.now < completionDeadline
            {
                await Task.yield()
            }

            _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))
            #expect(store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD == 2)
            #expect(self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))
        case .failure, .cancellation:
            while scanCount < 2 || store.tokenRefreshSequenceTask != nil,
                  ContinuousClock.now < completionDeadline
            {
                await Task.yield()
            }
            #expect(scanCount == 2)
            #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
            #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)
            #expect(!self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))
        }
    }

    private func trackedPopupTokenSnapshot(
        outcome: TrackedPopupTokenRefreshOutcome) throws -> CostUsageTokenSnapshot
    {
        switch outcome {
        case .success:
            self.tokenSnapshot(cost: 2)
        case .failure:
            throw TestRefreshError(message: "managed B scan failed")
        case .cancellation:
            throw CancellationError()
        }
    }

    private func menuItem(in menu: NSMenu, id: String) -> NSMenuItem? {
        menu.items.first { $0.representedObject as? String == id }
    }

    private func menuContainsRepresentedObject(_ id: String, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.representedObject as? String == id ||
                item.submenu.map { self.menuContainsRepresentedObject(id, in: $0) } == true
        }
    }

    private func tokenSnapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: Int(cost * 10),
            sessionCostUSD: cost,
            last30DaysTokens: Int(cost * 100),
            last30DaysCostUSD: cost,
            meteredCostUSD: cost,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-22",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: Int(cost * 10),
                    costUSD: cost,
                    modelsUsed: ["fixture-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())
    }
}

private enum TrackedPopupTokenRefreshOutcome {
    case success
    case failure
    case cancellation
}

@MainActor
private final class PhysicalTokenSnapshotLoaderGate {
    private struct Request {
        let homePath: String?
        var continuation: CheckedContinuation<CostUsageTokenSnapshot, any Error>?
    }

    private var requests: [Request] = []

    func load(homePath: String?) async throws -> CostUsageTokenSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.requests.append(Request(homePath: homePath, continuation: continuation))
        }
    }

    func waitForRequestCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.requests.count < count {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func homePaths() -> [String?] {
        self.requests.map(\.homePath)
    }

    func releaseRequest(
        at index: Int,
        with result: Result<CostUsageTokenSnapshot, any Error>) throws
    {
        try #require(self.requests.indices.contains(index))
        let continuation = try #require(self.requests[index].continuation)
        self.requests[index].continuation = nil
        continuation.resume(with: result)
    }

    func cleanup() {
        for index in self.requests.indices {
            guard let continuation = self.requests[index].continuation else { continue }
            self.requests[index].continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
