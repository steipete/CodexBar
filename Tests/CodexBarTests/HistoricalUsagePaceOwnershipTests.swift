import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension HistoricalUsagePaceTests {
    @Test
    func `history store ownership aware load aliases legacy email hash into canonical email hash`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)

        await Self.recordCompleteWeek(into: store, resetsAt: resetsAt, accountKey: legacyEmailHash)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: canonicalKey,
            canonicalEmailHashKey: canonicalKey,
            legacyEmailHash: legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset?.weeks.count == 1)
    }

    @Test
    func `history store ownership aware load keeps ambiguous nil key history unscoped`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let targetEmail = "person@example.com"
        let targetCanonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: targetEmail)
        let targetLegacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: targetEmail)
        let otherCanonicalKey = CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-other"))

        await Self.recordCompleteWeek(into: store, resetsAt: resetsAt, accountKey: nil)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: targetLegacyEmailHash)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 18,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60) + 60),
            accountKey: otherCanonicalKey)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: targetCanonicalKey,
            canonicalEmailHashKey: targetCanonicalKey,
            legacyEmailHash: targetLegacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset == nil)
    }

    @Test
    func `history store ownership aware load adopts nil key history only for strict single owner continuity`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)

        await Self.recordCompleteWeek(into: store, resetsAt: resetsAt, accountKey: nil)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: legacyEmailHash)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: canonicalKey,
            canonicalEmailHashKey: canonicalKey,
            legacyEmailHash: legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset?.weeks.count == 1)
    }

    @Test
    func `history store ignores later unrelated owners when evaluating nil key continuity`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let laterResetsAt = resetsAt.addingTimeInterval(21 * 24 * 60 * 60)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        let otherCanonicalKey = try #require(
            CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-other")))

        await Self.recordCompleteWeek(into: store, resetsAt: resetsAt, accountKey: nil)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: legacyEmailHash)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 18,
                windowMinutes: 10080,
                resetsAt: laterResetsAt,
                resetDescription: nil),
            sampledAt: laterResetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: otherCanonicalKey)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: canonicalKey,
            canonicalEmailHashKey: canonicalKey,
            legacyEmailHash: legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset?.weeks.count == 1)
        #expect(dataset?.weeks.first?.resetsAt == resetsAt)
    }

    @MainActor
    @Test
    func `refresh historical dataset keeps nil key history unscoped when managed and live accounts are distinct`()
        async throws
    {
        let historyStore = HistoricalUsageHistoryStore(fileURL: Self.makeTempURL())
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = Self.liveAccount(
            email: "live@example.com",
            identity: .providerAccount(id: "live-acct"))
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let managedLegacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: managedAccount.email)
        let managedCanonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: managedAccount.email)

        await Self.recordCompleteWeek(into: historyStore, resetsAt: resetsAt, accountKey: nil)
        _ = await historyStore.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: managedLegacyEmailHash)

        let store = try Self.makeUsageStoreForHistoricalTests(
            suite: "HistoricalUsagePaceTests-adjacent-veto",
            historicalUsageHistoryStore: historyStore)
        store.settings._test_activeManagedCodexAccount = managedAccount
        store.settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        store.settings._test_liveSystemCodexAccount = liveAccount
        defer {
            store.settings._test_activeManagedCodexAccount = nil
            store.settings._test_liveSystemCodexAccount = nil
            store.settings.codexActiveSource = .liveSystem
        }

        await store.refreshHistoricalDatasetIfNeeded()

        #expect(store.codexHistoricalDataset == nil)
        #expect(store.codexHistoricalDatasetAccountKey == managedCanonicalKey)
    }

    @MainActor
    @Test
    func `refresh historical dataset ignores extra saved managed accounts for adjacent veto`() async throws {
        let historyStore = HistoricalUsageHistoryStore(fileURL: Self.makeTempURL())
        let activeManagedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let inactiveManagedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            managedHomePath: "/tmp/other-codex-home",
            createdAt: 2,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let managedLegacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: activeManagedAccount.email)
        let managedCanonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: activeManagedAccount.email)

        await Self.recordCompleteWeek(into: historyStore, resetsAt: resetsAt, accountKey: nil)
        _ = await historyStore.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: resetsAt.addingTimeInterval(-(10080 * 60)),
            accountKey: managedLegacyEmailHash)

        let store = try Self.makeUsageStoreForHistoricalTests(
            suite: "HistoricalUsagePaceTests-saved-managed-accounts",
            historicalUsageHistoryStore: historyStore)
        let managedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoricalUsagePaceTests-\(UUID().uuidString)-managed-accounts.json")
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [activeManagedAccount, inactiveManagedAccount]))
        store.settings._test_managedCodexAccountStoreURL = managedStoreURL
        store.settings._test_activeManagedCodexAccount = activeManagedAccount
        store.settings.codexActiveSource = .managedAccount(id: activeManagedAccount.id)
        defer {
            store.settings._test_managedCodexAccountStoreURL = nil
            store.settings._test_activeManagedCodexAccount = nil
            store.settings.codexActiveSource = .liveSystem
        }

        await store.refreshHistoricalDatasetIfNeeded()

        #expect(store.codexHistoricalDataset?.weeks.count == 1)
        #expect(store.codexHistoricalDatasetAccountKey == managedCanonicalKey)
    }

    @Test
    func `history store ownership aware load merges legacy email hash into provider account continuity`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalEmailHashKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        let providerAccountKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-1")))

        await Self.recordCompleteWeek(into: store, resetsAt: resetsAt, accountKey: legacyEmailHash)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: providerAccountKey,
            canonicalEmailHashKey: canonicalEmailHashKey,
            legacyEmailHash: legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset?.weeks.count == 1)
    }

    @Test
    func `history store real local fixture aliases bare email hash into canonical continuity`() async throws {
        let fileURL = Self.makeTempURL()
        try Self.writeHistoricalFixture(named: "codex-historical-usage-real-legacy.jsonl", to: fileURL)
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let formatter = ISO8601DateFormatter()
        let normalizedEmail = "rdsarna@gmail.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalEmailHashKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        let providerAccountKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-123")))
        let fixtureResetAt = try #require(formatter.date(from: "2026-02-17T05:37:00Z"))
        let weekSeconds = TimeInterval(7 * 24 * 60 * 60)
        let weeksToShift = max(0, Int(ceil(Date().timeIntervalSince(fixtureResetAt) / weekSeconds)))
        let dateShift = TimeInterval(weeksToShift) * weekSeconds
        let records = try Self.readHistoricalRecords(from: fileURL)
        try Self.writeHistoricalRecords(
            records.map { record in
                HistoricalUsageRecord(
                    v: record.v,
                    provider: record.provider,
                    windowKind: record.windowKind,
                    source: record.source,
                    accountKey: record.accountKey,
                    sampledAt: record.sampledAt.addingTimeInterval(dateShift),
                    usedPercent: record.usedPercent,
                    resetsAt: record.resetsAt.addingTimeInterval(dateShift),
                    windowMinutes: record.windowMinutes)
            },
            to: fileURL)
        let expectedResetAt = fixtureResetAt.addingTimeInterval(dateShift)

        let dataset = await store.loadCodexDataset(
            canonicalAccountKey: providerAccountKey,
            canonicalEmailHashKey: canonicalEmailHashKey,
            legacyEmailHash: legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(dataset?.weeks.count == 1)
        #expect(dataset?.weeks.first?.resetsAt == expectedResetAt)
    }

    @MainActor
    @Test
    func `usage store records historical pace with canonical provider account key`() async throws {
        let historyFileURL = Self.makeTempURL()
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-provider-account-write",
            historyFileURL: historyFileURL)
        store.settings._test_liveSystemCodexAccount = Self.liveAccount(
            email: "person@example.com",
            identity: .providerAccount(id: "acct-123"))
        defer { store.settings._test_liveSystemCodexAccount = nil }

        let updatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let snapshot = Self.weeklySnapshot(
            email: "person@example.com",
            usedPercent: 42,
            resetsAt: updatedAt.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: updatedAt)

        store.recordCodexHistoricalSampleIfNeeded(snapshot: snapshot)
        let expectedKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-123")))
        let records = try await Self.waitForHistoricalWrite(
            store: store,
            at: historyFileURL,
            minimumCount: 1,
            expectedAccountKey: expectedKey)

        #expect(records.last?.accountKey == expectedKey)
        #expect(store.codexHistoricalDatasetAccountKey == expectedKey)
    }

    @MainActor
    @Test
    func `usage store records historical pace with canonical email hash key`() async throws {
        let historyFileURL = Self.makeTempURL()
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-email-hash-write",
            historyFileURL: historyFileURL)
        store.settings._test_liveSystemCodexAccount = Self.liveAccount(email: "person@example.com")
        defer { store.settings._test_liveSystemCodexAccount = nil }

        let updatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let snapshot = Self.weeklySnapshot(
            email: "Person@example.com",
            usedPercent: 42,
            resetsAt: updatedAt.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: updatedAt)

        store.recordCodexHistoricalSampleIfNeeded(snapshot: snapshot)
        let expectedKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "person@example.com")
        let records = try await Self.waitForHistoricalWrite(
            store: store,
            at: historyFileURL,
            minimumCount: 1,
            expectedAccountKey: expectedKey)

        #expect(records.last?.accountKey == expectedKey)
        #expect(store.codexHistoricalDatasetAccountKey == expectedKey)
    }

    @MainActor
    @Test
    func `refresh historical dataset aliases legacy email hash into canonical email hash`() async throws {
        let historyFileURL = Self.makeTempURL()
        let historyStore = HistoricalUsageHistoryStore(fileURL: historyFileURL)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let canonicalKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        await Self.recordCompleteWeek(into: historyStore, resetsAt: resetsAt, accountKey: legacyEmailHash)

        let store = try Self.makeUsageStoreForHistoricalTests(
            suite: "HistoricalUsagePaceTests-refresh-legacy-alias",
            historicalUsageHistoryStore: historyStore)
        store.settings._test_liveSystemCodexAccount = Self.liveAccount(email: normalizedEmail)
        defer { store.settings._test_liveSystemCodexAccount = nil }

        await store.refreshHistoricalDatasetIfNeeded()

        #expect(store.codexHistoricalDatasetAccountKey == canonicalKey)
        #expect(store.codexHistoricalDataset?.weeks.count == 1)
    }

    @MainActor
    @Test
    func `refresh historical dataset carries matching email continuity into provider account`() async throws {
        let historyFileURL = Self.makeTempURL()
        let historyStore = HistoricalUsageHistoryStore(fileURL: historyFileURL)
        let normalizedEmail = "person@example.com"
        let legacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: normalizedEmail)
        let providerAccountKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-123")))
        let resetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        await Self.recordCompleteWeek(into: historyStore, resetsAt: resetsAt, accountKey: legacyEmailHash)

        let store = try Self.makeUsageStoreForHistoricalTests(
            suite: "HistoricalUsagePaceTests-refresh-provider-account-continuity",
            historicalUsageHistoryStore: historyStore)
        store.settings._test_liveSystemCodexAccount = Self.liveAccount(
            email: normalizedEmail,
            identity: .providerAccount(id: "acct-123"))
        defer { store.settings._test_liveSystemCodexAccount = nil }

        await store.refreshHistoricalDatasetIfNeeded()

        #expect(store.codexHistoricalDatasetAccountKey == providerAccountKey)
        #expect(store.codexHistoricalDataset?.weeks.count == 1)
    }

    @MainActor
    @Test
    func `refresh historical dataset ignores stale dashboard signals and uses active account ownership`() async throws {
        let historyFileURL = Self.makeTempURL()
        let historyStore = HistoricalUsageHistoryStore(fileURL: historyFileURL)
        let staleEmail = "old@example.com"
        let staleLegacyEmailHash = CodexHistoryOwnership.legacyEmailHash(normalizedEmail: staleEmail)
        let staleResetsAt = Date(timeIntervalSince1970: 1_770_000_000)
        await Self.recordCompleteWeek(into: historyStore, resetsAt: staleResetsAt, accountKey: staleLegacyEmailHash)

        let store = try Self.makeUsageStoreForHistoricalTests(
            suite: "HistoricalUsagePaceTests-refresh-prefers-active-email",
            historicalUsageHistoryStore: historyStore)
        let activeProviderAccountKey = try #require(
            CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-new")))
        store.settings._test_liveSystemCodexAccount = Self.liveAccount(
            email: "new@example.com",
            identity: .providerAccount(id: "acct-new"))
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: staleEmail,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: staleResetsAt)
        store.lastOpenAIDashboardTargetEmail = staleEmail
        defer { store.settings._test_liveSystemCodexAccount = nil }

        await store.refreshHistoricalDatasetIfNeeded()

        #expect(store.codexHistoricalDatasetAccountKey == activeProviderAccountKey)
        #expect(store.codexHistoricalDataset == nil)
    }
}
