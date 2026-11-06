import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `stacked refresh schedules only the selected accounts reset card`() async throws {
        let store = try self.makeAutoRedeemStore()
        let settings = store.settings
        settings.multiAccountMenuLayout = .stacked
        let managedID = UUID()
        let managedHome = CodexCredentialFixtures.root.appendingPathComponent("inactive")
        let managed = ManagedCodexAccount(
            id: managedID,
            email: "inactive@example.com",
            providerAccountID: "inactive-account",
            workspaceAccountID: "inactive-account",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managed])
        settings._test_managedCodexAccountStoreURL = storeURL
        defer {
            store.codexResetCreditAutoRedeemer.cancel()
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        let selectedInventory = Self.autoRedeemInventory(seconds: 3600)
        let selected = self.codexSnapshot(email: "fixture@example.com", usedPercent: 90)
            .withCodexResetCredits(selectedInventory)
        let inactive = self.codexSnapshot(email: "inactive@example.com", usedPercent: 90)
            .withCodexResetCredits(Self.autoRedeemInventory(id: "inactive-card", seconds: 180))
        self.installContextualCodexProvider(on: store) { context in
            context.env["CODEX_HOME"] == managedHome.path ? inactive : selected
        }

        await store.refreshProvider(.codex)

        #expect(store.codexAccountSnapshots.count == 2)
        #expect(store.codexResetCreditAutoRedeemer.plan?.creditID == selectedInventory.credits.first?.id)
        let owner = try #require(UsageStore.codexSessionQuotaOwnerKey(
            for: store.freshCodexAccountScopedRefreshGuard()))
        #expect(store.codexResetCreditAutoRedeemer.plan?.owner == owner.rawValue + ":live-system")
    }

    @Test
    func `successful reset card consumption replaces an in flight pre redemption usage fetch`() async throws {
        let store = try self.makeAutoRedeemStore()
        let inventory = Self.autoRedeemInventory()
        let old = self.codexSnapshot(email: "fixture@example.com", usedPercent: 90)
        let fresh = self.codexSnapshot(email: "fixture@example.com", usedPercent: 0)
        let loader = SequencedCodexSnapshotLoader(steps: [.success(old, gated: true), .success(fresh)])
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let preRedemptionRefresh = Task { await store.refreshProvider(.codex) }
        defer {
            preRedemptionRefresh.cancel()
            store.codexResetCreditAutoRedeemer.cancel()
        }
        #expect(await loader.waitUntilCallCount(1))
        let posted = AsyncStream<Void>.makeStream()
        let transport = Self.autoRedeemTransport(inventory: inventory)
        let recording = ProviderHTTPTransportStub { request in
            let response = try await transport.data(for: request)
            if request.httpMethod == "POST" { posted.continuation.yield() }
            return response
        }
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(recording) {
            store.scheduleCodexResetCreditAutoRedeem(
                snapshot: old.withCodexResetCredits(inventory),
                expectedGuard: store.freshCodexAccountScopedRefreshGuard())
            let redemptionTask = store.codexResetCreditAutoRedeemer.task
            var iterator = posted.stream.makeAsyncIterator()
            _ = await iterator.next()
            await loader.release(call: 1)
            await redemptionTask?.value
        }
        await preRedemptionRefresh.value
        posted.continuation.finish()

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 0)
        #expect(await recording.requests().map(\.httpMethod) == ["GET", "POST"])
    }

    @Test(arguments: ["opt-in", "account", "member", "source"])
    func `production authorization blocks queued reset card requests after revocation`(change: String) async throws {
        let store = try self.makeAutoRedeemStore()
        let inventory = Self.autoRedeemInventory()
        let transport = Self.autoRedeemTransport(inventory: inventory)
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            store.scheduleCodexResetCreditAutoRedeem(
                snapshot: self.codexSnapshot(email: "fixture@example.com", usedPercent: 90)
                    .withCodexResetCredits(inventory),
                expectedGuard: store.freshCodexAccountScopedRefreshGuard())
            let task = store.codexResetCreditAutoRedeemer.task
            self.revokeAutoRedemption(change, store: store)
            await task?.value
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test(arguments: ["opt-in", "account", "member", "source"])
    func `production authorization blocks POST after revocation during inventory GET`(change: String) async throws {
        let store = try self.makeAutoRedeemStore()
        let inventory = Self.autoRedeemInventory()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let response = Self.autoRedeemTransport(inventory: inventory)
        let transport = ProviderHTTPTransportStub { request in
            if request.httpMethod == "GET" {
                started.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return try await response.data(for: request)
        }
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            store.scheduleCodexResetCreditAutoRedeem(
                snapshot: self.codexSnapshot(email: "fixture@example.com", usedPercent: 90)
                    .withCodexResetCredits(inventory),
                expectedGuard: store.freshCodexAccountScopedRefreshGuard())
            let task = store.codexResetCreditAutoRedeemer.task
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
            self.revokeAutoRedemption(change, store: store)
            release.continuation.yield()
            await task?.value
        }
        started.continuation.finish()
        release.continuation.finish()
        #expect(await transport.requests().map(\.httpMethod) == ["GET"])
    }

    private func makeAutoRedeemStore() throws -> UsageStore {
        let settings = self.makeSettingsStore(suite: #function)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.codexResetCreditAutoRedeemEnabled = true
        enableTestProviders([.codex], settings: settings)
        let home = CodexCredentialFixtures.root.appendingPathComponent("live")
        try Self.writeCodexAuthFile(
            homeURL: home, email: "fixture@example.com", plan: "Pro", accountId: "fixture-account")
        let url = home.appendingPathComponent("auth.json")
        var auth = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        auth["last_refresh"] = formatter.string(from: Date())
        try JSONSerialization.data(withJSONObject: auth).write(to: url)
        let alternate = CodexCredentialFixtures.root.appendingPathComponent("alternate")
        try FileManager.default.copyItem(at: home, to: alternate)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "fixture@example.com",
            workspaceAccountID: "fixture-account",
            codexHomePath: home.path,
            observedAt: Date(),
            identity: .providerAccount(id: "fixture-account"))
        let store = self.makeUsageStore(settings: settings, environmentBase: ["CODEX_HOME": home.path])
        store._test_codexResetCreditsFetcherOverride = { _ in nil }
        return store
    }

    private func revokeAutoRedemption(_ change: String, store: UsageStore) {
        switch change {
        case "opt-in":
            store.settings.codexResetCreditAutoRedeemEnabled = false
        case "account", "member":
            store.settings._test_liveSystemCodexAccount = self.liveAccount(
                email: change == "member" ? "other-member@example.com" : "fixture@example.com",
                identity: .providerAccount(id: change == "account" ? "other-account" : "fixture-account"))
        case "source":
            store.settings.codexActiveSource = .profileHome(
                path: CodexCredentialFixtures.root.appendingPathComponent("alternate").path)
        default:
            Issue.record("Unknown revocation fixture")
        }
    }

    private static func autoRedeemInventory(
        id: String = "fixture-provider-id", seconds: TimeInterval = 180) -> CodexRateLimitResetCreditsSnapshot
    {
        let now = Date()
        return CodexRateLimitResetCreditsSnapshot(
            credits: [CodexRateLimitResetCredit(
                id: id,
                resetType: "codex_rate_limits",
                status: .available,
                grantedAt: now.addingTimeInterval(-86400),
                expiresAt: now.addingTimeInterval(seconds),
                redeemStartedAt: nil,
                redeemedAt: nil,
                title: nil,
                description: nil)],
            availableCount: 1,
            updatedAt: now)
    }

    private static func autoRedeemTransport(inventory: CodexRateLimitResetCreditsSnapshot)
    -> ProviderHTTPTransportStub {
        CodexResetCreditRedemptionTests.transport(
            seconds: inventory.credits[0].expiresAt!.timeIntervalSince(CodexResetCreditRedemptionTests.now))
    }
}
