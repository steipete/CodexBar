import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationClaudeIdentityTests {
    @MainActor
    @Test
    func `selected token account chooses matching bucket`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))

        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(accounts: [
            aliceKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ])],
            bobKey: [planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 50),
            ])],
        ])

        #expect(store.planUtilizationHistory(for: .claude) == [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ]),
        ])

        store.settings.setActiveTokenAccountIndex(1, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 50),
            ]),
        ])
    }

    @MainActor
    @Test
    func `fetched non selected accounts persist into separate claude buckets`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: bob))

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "bob@example.com",
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: .claude,
            samples: [(account: bob, snapshot: snapshot)],
            selectedAccount: alice)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let histories = try #require(buckets.accounts[bobKey])
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 20)
        #expect(findSeries(histories, name: .opus, windowMinutes: 10080)?.entries.last?.usedPercent == 30)
    }

    @MainActor
    @Test
    func `first resolved claude token account adopts unscoped history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        let alice = try #require(store.settings.tokenAccounts(for: .claude).first)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: alice))
        let bootstrap = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 15),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [bootstrap])
        store.settings.setActiveTokenAccountIndex(0, for: .claude)

        let history = store.planUtilizationHistory(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])

        #expect(history == [bootstrap])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts[aliceKey] == [bootstrap])
    }

    @MainActor
    @Test
    func `claude oauth credential owner separates switched account history`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let accountBOwner = self.oauthOwnerIdentifier("b")
        let accountASnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "max"))
        let accountAKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: accountASnapshot))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountASnapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let accountBSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let accountBKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: accountBOwner))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountBSnapshot,
            claudeOAuthPersistentRefHash: "account-b-ref",
            claudeOAuthHistoryOwnerIdentifier: accountBOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_007_200))
        store._setSnapshotForTesting(accountBSnapshot, provider: .claude)

        let selectedHistory = store.planUtilizationHistory(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        let accountAHistory = try #require(buckets.accounts[accountAKey])
        let accountBHistory = try #require(buckets.accounts[accountBKey])

        #expect(buckets.preferredAccountKey == accountBKey)
        #expect(buckets.unscoped.isEmpty)
        #expect(findSeries(accountAHistory, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(accountAHistory, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 20)
        #expect(findSeries(accountBHistory, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 70)
        #expect(findSeries(accountBHistory, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 80)
        #expect(findSeries(selectedHistory, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 70)
    }

    @MainActor
    @Test
    func `claude oauth credential owner wins over configured token account`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let oauthOwner = self.oauthOwnerIdentifier("a")
        store.settings.addTokenAccount(provider: .claude, label: "Unrelated", token: "unrelated-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        let selectedAccount = try #require(store.settings.selectedTokenAccount(for: .claude))
        let tokenAccountKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: selectedAccount))
        let oauthAccountKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: oauthOwner))
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 45, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthPersistentRefHash: "oauth-ref",
            claudeOAuthHistoryOwnerIdentifier: oauthOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let selection = store.planUtilizationHistorySelection(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.preferredAccountKey == oauthAccountKey)
        #expect(buckets.accounts[tokenAccountKey] == nil)
        #expect(findSeries(buckets.accounts[oauthAccountKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [45])
        #expect(selection.accountKey == oauthAccountKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [45])
    }

    @MainActor
    @Test
    func `claude oauth without credential ownership is not persisted`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Unrelated", token: "unrelated-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        let selectedAccount = try #require(store.settings.selectedTokenAccount(for: .claude))
        let tokenAccountKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: selectedAccount))
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthPersistentRefHash: "row-only-ref",
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let selection = store.planUtilizationHistorySelection(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.isEmpty)
        #expect(buckets.accounts.isEmpty)
        #expect(selection.accountKey == tokenAccountKey)
        #expect(selection.histories.isEmpty)
    }

    @MainActor
    @Test
    func `coalesced claude oauth sample still switches preferred account`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let accountAOwner = self.oauthOwnerIdentifier("a")
        let accountBOwner = self.oauthOwnerIdentifier("b")
        let accountAKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: accountAOwner))
        let accountBKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: accountBOwner))
        let hourStart = Date(timeIntervalSince1970: 1_700_000_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 70),
            claudeOAuthPersistentRefHash: "account-a-ref",
            claudeOAuthHistoryOwnerIdentifier: accountAOwner,
            isClaudeOAuthSample: true,
            now: hourStart)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 40),
            claudeOAuthPersistentRefHash: "account-b-ref",
            claudeOAuthHistoryOwnerIdentifier: accountBOwner,
            isClaudeOAuthSample: true,
            now: hourStart.addingTimeInterval(5 * 60))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 60),
            claudeOAuthPersistentRefHash: "account-a-ref",
            claudeOAuthHistoryOwnerIdentifier: accountAOwner,
            isClaudeOAuthSample: true,
            now: hourStart.addingTimeInterval(10 * 60))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let selection = store.planUtilizationHistorySelection(for: .claude)
        #expect(buckets.preferredAccountKey == accountAKey)
        #expect(findSeries(buckets.accounts[accountAKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [70])
        #expect(findSeries(buckets.accounts[accountBKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [40])
        #expect(selection.accountKey == accountAKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [70])
    }

    @MainActor
    @Test
    func `same dir account switch quarantines stale background credential`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let ownerA = self.oauthOwnerIdentifier("a")
        let ownerB = self.oauthOwnerIdentifier("b")
        let keyA = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: ownerA))
        let keyB = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: ownerB))
        let hourStart = Date(timeIntervalSince1970: 1_700_000_000)

        // 1) Active account A (~/.claude.json = uuid-A). Two stable exact-Keychain observations bind owner_A
        //    to A; the short confirmation interval does not add a second history point.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-A") {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 30),
                    claudeOAuthPersistentRefHash: "account-a-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")),
                    isClaudeOAuthSample: true,
                    now: hourStart)
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 30),
                    claudeOAuthPersistentRefHash: "account-a-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(30 * 60))
            }
        }

        do {
            let buckets = try #require(store.planUtilizationHistory[.claude])
            #expect(findSeries(buckets.accounts[keyA] ?? [], name: .session, windowMinutes: 300)?
                .entries.map(\.usedPercent) == [30])
            #expect(buckets.unscoped.isEmpty)
        }

        // 2) `/login` switched the active account to B (~/.claude.json = uuid-B), but the gated BACKGROUND
        //    poll still serves the STALE owner_A credential. Prompt-free Keychain comparison is unavailable,
        //    but the existing owner_A -> uuid-A binding detects the mismatch, so this must be quarantined:
        //    no new sample lands.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-B") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 90),
                    claudeOAuthPersistentRefHash: nil,
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthKeychainCredentialUnavailable: true,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(2 * 60 * 60))
            }
        }

        do {
            let buckets = try #require(store.planUtilizationHistory[.claude])
            // key_A history is UNCHANGED (the stale sample was dropped, not appended).
            #expect(findSeries(buckets.accounts[keyA] ?? [], name: .session, windowMinutes: 300)?
                .entries.map(\.usedPercent) == [30])
            // Critically, the quarantined sample did NOT leak into the shared unscoped bucket. This is the
            // assertion that catches the naive-nil bug (nil accountKey writes to `unscoped`, not nowhere).
            #expect(buckets.unscoped.isEmpty)
            #expect(buckets.accounts[keyB] == nil)
        }

        // 3) A USER-INITIATED refresh yields account B's real credential (owner_B), with exact current-Keychain
        //    match evidence. Recovery: bind owner_B -> uuid-B, write to key_B, and leave key_A untouched.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-B") {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 75),
                    claudeOAuthPersistentRefHash: "account-b-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerB,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(3 * 60 * 60))
            }
        }

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[keyB] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [75])
        #expect(findSeries(buckets.accounts[keyA] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [30])
        #expect(buckets.unscoped.isEmpty)
    }

    @MainActor
    @Test
    func `exact keychain match arms account map on background poll`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let ownerA = self.oauthOwnerIdentifier("a")
        let ownerB = self.oauthOwnerIdentifier("b")
        let keyA = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: ownerA))
        let keyB = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: ownerB))
        let hourStart = Date(timeIntervalSince1970: 1_700_000_000)

        // 1) First run after upgrading: the map is empty. A background poll serves owner_A while
        //    ~/.claude.json reports uuid-A, and exact current-Keychain evidence corroborates the credential.
        //    The first observation stages a candidate; a later identical observation confirms the binding.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-A") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 30),
                    claudeOAuthPersistentRefHash: "account-a-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")),
                    isClaudeOAuthSample: true,
                    now: hourStart)
            }
        }

        let accountAIdentity = UsageStore._activeClaudeAccountIdentityForTesting("uuid-A")
        let accountBIdentity = UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")
        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults)[ownerA] == nil)
        #expect(UsageStore.loadClaudeOAuthAccountBindingCandidateMap(
            from: store.settings.userDefaults)[ownerA]?.identity == accountAIdentity)

        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-A") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 30),
                    claudeOAuthPersistentRefHash: "account-a-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthActiveAccountObservation: .stable(identity: accountAIdentity),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(30 * 60))
            }
        }
        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(
            from: store.settings.userDefaults)[ownerA] == accountAIdentity)

        // 2) `/login` switched to account B (~/.claude.json = uuid-B), but the gated BACKGROUND poll still
        //    serves the stale owner_A credential. It no longer matches the current Keychain item, and the
        //    existing owner_A -> uuid-A binding detects the UUID mismatch, so the sample is quarantined.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-B") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 90),
                    claudeOAuthPersistentRefHash: nil,
                    claudeOAuthHistoryOwnerIdentifier: ownerA,
                    claudeOAuthKeychainCredentialMismatch: true,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(2 * 60 * 60))
            }
        }

        do {
            let mapAfterBackground = UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults)
            #expect(mapAfterBackground[ownerA] == accountAIdentity)
            let buckets = try #require(store.planUtilizationHistory[.claude])
            #expect(findSeries(buckets.accounts[keyA] ?? [], name: .session, windowMinutes: 300)?
                .entries.map(\.usedPercent) == [30])
            #expect(buckets.unscoped.isEmpty)
        }

        // 3) A background poll now yields account B's real credential (owner_B) with exact current-Keychain
        //    match evidence. That evidence, not the interaction label, binds owner_B -> uuid-B and writes key_B.
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-B") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 75),
                    claudeOAuthPersistentRefHash: "account-b-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerB,
                    claudeOAuthActiveAccountObservation: .stable(
                        identity: UsageStore._activeClaudeAccountIdentityForTesting("uuid-B")),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(3 * 60 * 60))
            }
        }

        #expect(UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults)[ownerB] == nil)
        await UsageStore.withActiveClaudeAccountUuidForTesting("uuid-B") {
            await ProviderInteractionContext.$current.withValue(.background) {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: self.identitylessClaudeSnapshot(usedPercent: 75),
                    claudeOAuthPersistentRefHash: "account-b-ref",
                    claudeOAuthHistoryOwnerIdentifier: ownerB,
                    claudeOAuthActiveAccountObservation: .stable(identity: accountBIdentity),
                    isClaudeOAuthSample: true,
                    now: hourStart.addingTimeInterval(3 * 60 * 60 + 30 * 60))
            }
        }

        let mapAfterRecovery = UsageStore.loadClaudeOAuthAccountUuidMap(from: store.settings.userDefaults)
        #expect(mapAfterRecovery[ownerB] == accountBIdentity)
        #expect(mapAfterRecovery[ownerA] == accountAIdentity)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(findSeries(buckets.accounts[keyB] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [75])
        #expect(buckets.unscoped.isEmpty)
    }

    @MainActor
    @Test
    func `coalesced claude oauth sample without owner cannot switch preferred account`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let scopedOwner = self.oauthOwnerIdentifier("c")
        let scopedAccountKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: scopedOwner))
        let hourStart = Date(timeIntervalSince1970: 1_700_000_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 70),
            isClaudeOAuthSample: true,
            now: hourStart)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 40),
            claudeOAuthPersistentRefHash: "scoped-ref",
            claudeOAuthHistoryOwnerIdentifier: scopedOwner,
            isClaudeOAuthSample: true,
            now: hourStart.addingTimeInterval(5 * 60))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 60),
            isClaudeOAuthSample: true,
            now: hourStart.addingTimeInterval(10 * 60))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let selection = store.planUtilizationHistorySelection(for: .claude)
        #expect(buckets.preferredAccountKey == scopedAccountKey)
        #expect(buckets.unscoped.isEmpty)
        #expect(findSeries(buckets.accounts[scopedAccountKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [40])
        #expect(selection.accountKey == scopedAccountKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [40])
    }

    @MainActor
    @Test
    func `reloaded scoped claude oauth preference wins over configured token account`() throws {
        let oauthOwner = self.oauthOwnerIdentifier("a")
        let oauthAccountKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: oauthOwner))
        let oauthHistory = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 45),
        ])
        let store = self.makeReloadedStoreWithConfiguredTokenAccount(
            buckets: PlanUtilizationHistoryBuckets(
                preferredAccountKey: oauthAccountKey,
                accounts: [oauthAccountKey: [oauthHistory]]))

        #expect(store.lastSourceLabels[.claude] == nil)
        #expect(store.settings.selectedTokenAccount(for: .claude) != nil)

        let selection = store.planUtilizationHistorySelection(for: .claude)

        #expect(selection.accountKey == oauthAccountKey)
        #expect(selection.histories == [oauthHistory])
        #expect(store.planUtilizationHistory[.claude]?.preferredAccountKey == oauthAccountKey)
    }

    @MainActor
    @Test
    func `reloaded unscoped claude oauth preference wins over configured token account`() {
        let oauthHistory = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 55),
        ])
        let store = self.makeReloadedStoreWithConfiguredTokenAccount(
            buckets: PlanUtilizationHistoryBuckets(
                preferredAccountKey: "__unscoped__",
                unscoped: [oauthHistory]))

        #expect(store.lastSourceLabels[.claude] == nil)
        #expect(store.settings.selectedTokenAccount(for: .claude) != nil)

        let selection = store.planUtilizationHistorySelection(for: .claude)

        #expect(selection.accountKey == nil)
        #expect(selection.histories == [oauthHistory])
        #expect(store.planUtilizationHistory[.claude]?.preferredAccountKey == "__unscoped__")
    }

    @MainActor
    @Test
    func `later token account sample supersedes claude oauth preference`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let oauthOwner = self.oauthOwnerIdentifier("a")
        store.settings.addTokenAccount(provider: .claude, label: "Selected", token: "selected-token")
        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        let selectedAccount = try #require(store.settings.selectedTokenAccount(for: .claude))
        let tokenAccountKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: selectedAccount))
        let oauthAccountKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: oauthOwner))
        let oauthSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 45, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: oauthSnapshot,
            claudeOAuthPersistentRefHash: "oauth-ref",
            claudeOAuthHistoryOwnerIdentifier: oauthOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let tokenSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: tokenSnapshot,
            account: selectedAccount,
            now: Date(timeIntervalSince1970: 1_700_007_200))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let selection = store.planUtilizationHistorySelection(for: .claude)
        #expect(buckets.preferredAccountKey == tokenAccountKey)
        #expect(findSeries(buckets.accounts[oauthAccountKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [45])
        #expect(selection.accountKey == tokenAccountKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [20])
    }

    @MainActor
    @Test
    func `first claude oauth owner quarantines legacy unscoped history`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let currentOwner = self.oauthOwnerIdentifier("c")
        let legacy = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 25),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: [legacy])

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let accountKey = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: currentOwner))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthPersistentRefHash: "current-ref",
            claudeOAuthHistoryOwnerIdentifier: currentOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_007_200))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let scoped = try #require(buckets.accounts[accountKey])
        #expect(buckets.unscoped == [legacy])
        #expect(findSeries(scoped, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [60])
        #expect(buckets.preferredAccountKey == accountKey)
    }

    @MainActor
    @Test
    func `provenance-less claude oauth credentials stay isolated across restart`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let accountAOwner = self.oauthOwnerIdentifier("a")
        let accountBOwner = self.oauthOwnerIdentifier("b")
        let accountAKey = try #require(UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
            historyOwnerIdentifier: accountAOwner))
        let accountBKey = try #require(UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
            historyOwnerIdentifier: accountBOwner))

        await UsageStore.withActiveClaudeAccountUuidForTesting(nil) {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: self.identitylessClaudeSnapshot(usedPercent: 10),
                claudeOAuthHistoryOwnerIdentifier: accountAOwner,
                isClaudeOAuthSample: true,
                now: Date(timeIntervalSince1970: 1_700_000_000))
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: self.identitylessClaudeSnapshot(usedPercent: 75),
                claudeOAuthHistoryOwnerIdentifier: accountBOwner,
                isClaudeOAuthSample: true,
                now: Date(timeIntervalSince1970: 1_700_007_200))
        }

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.unscoped.isEmpty)
        #expect(findSeries(buckets.accounts[accountAKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [10])
        #expect(findSeries(buckets.accounts[accountBKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [75])

        let reloaded = self.makeReloadedStoreWithConfiguredTokenAccount(buckets: buckets)
        let selection = reloaded.planUtilizationHistorySelection(for: .claude)
        #expect(selection.accountKey == accountBKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [75])
        #expect(reloaded.planUtilizationHistory[.claude]?.accounts[accountAKey] != nil)
    }

    @MainActor
    @Test
    func `same keychain reference credential replacement stays isolated across restart`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let originalOwner = self.oauthOwnerIdentifier("c")
        let replacementOwner = self.oauthOwnerIdentifier("d")
        let originalKey = try #require(UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
            historyOwnerIdentifier: originalOwner,
            persistentRefHash: "same-row-ref"))
        let replacementKey = try #require(UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
            historyOwnerIdentifier: replacementOwner,
            persistentRefHash: "same-row-ref"))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 25),
            claudeOAuthPersistentRefHash: "same-row-ref",
            claudeOAuthHistoryOwnerIdentifier: originalOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: self.identitylessClaudeSnapshot(usedPercent: 80),
            claudeOAuthPersistentRefHash: "same-row-ref",
            claudeOAuthHistoryOwnerIdentifier: replacementOwner,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_007_200))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(originalKey != replacementKey)
        #expect(findSeries(buckets.accounts[originalKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [25])
        #expect(findSeries(buckets.accounts[replacementKey] ?? [], name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [80])

        let reloaded = self.makeReloadedStoreWithConfiguredTokenAccount(buckets: buckets)
        let selection = reloaded.planUtilizationHistorySelection(for: .claude)
        #expect(selection.accountKey == replacementKey)
        #expect(findSeries(selection.histories, name: .session, windowMinutes: 300)?
            .entries.map(\.usedPercent) == [80])
        #expect(reloaded.planUtilizationHistory[.claude]?.accounts[originalKey] != nil)
    }

    @Test
    func `claude oauth history key is stable for one credential owner`() throws {
        let owner = self.oauthOwnerIdentifier("a")
        let first = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(historyOwnerIdentifier: owner))
        let refreshed = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: " \(owner.uppercased()) "))
        let switched = try #require(
            UsageStore._claudeOAuthPlanUtilizationAccountKeyForTesting(
                historyOwnerIdentifier: self.oauthOwnerIdentifier("b")))

        #expect(first == refreshed)
        #expect(first != switched)
        #expect(first != owner)
        #expect(first.hasPrefix("__claude_oauth__:"))
        #expect(first.dropFirst("__claude_oauth__:".count).count == 64)
    }

    @Test
    func `same claude email separates team and personal plan history keys`() throws {
        let team = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: "Team Org",
                loginMethod: "Claude Team"))
        let max = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: "Claude Max"))

        let teamKey = try #require(UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: team))
        let maxKey = try #require(UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: max))

        #expect(teamKey != maxKey)
    }

    @Test
    func `claude email only identity keeps legacy history key`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let identityKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: snapshot))
        let legacyKey = try #require(
            UsageStore._legacyClaudePlanUtilizationEmailAccountKeyForTesting(snapshot: snapshot))

        #expect(identityKey == legacyKey)
    }

    @Test
    func `claude compact and branded plan labels share history key`() throws {
        let compact = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
        let branded = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: "Claude Max"))

        let compactKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: compact))
        let brandedKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: branded))

        #expect(compactKey == brandedKey)
    }

    @MainActor
    @Test
    func `new claude email discriminator adopts legacy email history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: "Team Org",
                loginMethod: "Claude Team"))
        let legacyKey = try #require(
            UsageStore._legacyClaudePlanUtilizationEmailAccountKeyForTesting(snapshot: snapshot))
        let accountKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(provider: .claude, snapshot: snapshot))
        let legacyWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 42),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            preferredAccountKey: legacyKey,
            accounts: [
                legacyKey: [legacyWeekly],
            ])
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let history = store.planUtilizationHistory(for: .claude)
        let buckets = try #require(store.planUtilizationHistory[.claude])

        #expect(history == [legacyWeekly])
        #expect(buckets.accounts[legacyKey] == nil)
        #expect(buckets.accounts[accountKey] == [legacyWeekly])
        #expect(buckets.preferredAccountKey == accountKey)
    }

    private func oauthOwnerIdentifier(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func identitylessClaudeSnapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    @MainActor
    private func makeReloadedStoreWithConfiguredTokenAccount(
        buckets: PlanUtilizationHistoryBuckets) -> UsageStore
    {
        let suiteName = "UsageStorePlanUtilizationClaudeReload-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite for tests")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
        historyStore.save([.claude: buckets])
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.addTokenAccount(provider: .claude, label: "Unrelated", token: "unrelated-token")
        settings.setActiveTokenAccountIndex(0, for: .claude)
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing)
    }
}
