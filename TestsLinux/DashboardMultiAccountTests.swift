import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardMultiAccountTests {
    @Test
    func `account enumeration is a serve only opt in`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let ordinary = try program.resolve(argv: ["serve"])
        let expanded = try program.resolve(argv: ["serve", "--all-accounts"])
        #expect(!ordinary.parsedValues.flags.contains("allAccounts"))
        #expect(expanded.parsedValues.flags.contains("allAccounts"))
        #expect(throws: (any Error).self) { try program.resolve(argv: ["dashboard", "--all-accounts"]) }
    }

    @Test
    func `two profiles group and non first active drives compatibility fields and cache key`() async throws {
        let first = self.payload(id: "one", active: false, used: 10)
        let second = self.payload(id: "two", active: true, used: 65)
        let producer = DashboardSnapshotProducer(
            collectUsage: { _ in UsageCommandOutput(payload: [first, second]) },
            collectCost: { _, _ in [] },
            now: { Date(timeIntervalSince1970: 0) },
            usageBarsShowUsed: { true },
            allAccounts: true)
        let result = try await producer.collect(
            config: self.config, refreshInterval: 60, codexBarVersion: nil, identityMode: .full)
        let row = try #require(result.payload.providers.first)
        let accounts = try #require(row.accounts)
        #expect(result.payload.providers.count == 1)
        #expect(accounts.map(\.id) == ["one", "two"])
        #expect(accounts.map(\.active) == [false, true])
        #expect(row.windows.first?.usedPercent == 65)
        #expect(row.identity?.accountEmail == "two@example.test")
        #expect(result.usageCacheKeys == ["private:two@example.test"])
        #expect(result.payload.host.usageBarsShowUsed)
    }

    @Test
    func `expired sibling stays local and redaction covers labels identities and errors`() throws {
        let failed = self.payload(id: "one", active: false, error: "Expired one@example.test")
        let healthy = self.payload(id: "two", active: true, used: 65)
        let snapshot = self.snapshot([failed, healthy], mode: .redacted)
        let row = try #require(snapshot.providers.first)
        let accounts = try #require(row.accounts)
        #expect(row.error == nil)
        #expect(row.windows.first?.usedPercent == 65)
        #expect(accounts[0].windows.isEmpty)
        #expect(accounts[0].error == "Account usage unavailable")
        #expect(accounts[1].windows.first?.usedPercent == 65)
        let json = try #require(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        #expect(!json.contains("one@example.test"))
        #expect(!json.contains("two@example.test"))
        #expect(!json.contains("private:"))
        #expect(!json.contains("cacheAccountKey"))
        #expect(!json.contains("dashboardAccount"))
    }

    @Test
    func `failed active account is not replaced by healthy sibling and its error is redacted`() throws {
        let snapshot = self.snapshot([
            self.payload(id: "one", active: false, used: 10),
            self.payload(id: "two", active: true, error: "Expired two@example.test"),
        ], mode: .redacted)
        let row = try #require(snapshot.providers.first)
        #expect(row.windows.isEmpty)
        #expect(row.error?.message == "Account usage unavailable")
        #expect(row.accounts?.first?.windows.first?.usedPercent == 10)
        let none = self.snapshot([self.payload(id: "two", active: true, error: "two@example.test")], mode: .none)
        #expect(none.providers.first?.accounts?.first?.label == "Account 1")
        #expect(none.providers.first?.accounts?.first?.identity == nil)
        #expect(none.providers.first?.error?.message == "Account usage unavailable")
    }

    @Test
    func `default dashboard shape and raw usage encoding do not expose new metadata`() throws {
        let payload = self.payload(id: "one", active: true, used: 10)
        let snapshot = self.snapshot([payload], allAccounts: false)
        #expect(snapshot.providers.count == 1)
        #expect(snapshot.providers.first?.accounts == nil)
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(!json.contains("dashboardAccount"))
        #expect(!json.contains("cacheAccountKey"))
        #expect(!json.contains("private:"))
        let context = ServeUsageContext(
            config: self.config,
            configFingerprint: "fixture",
            refreshInterval: 60,
            providerTimeout: nil,
            providerDeadline: nil,
            providerOperations: CLIServeOperationCoordinator())
        #expect(context.includeAllCodexAccounts)
        #expect(!context.includeAllAccounts)
    }

    @Test
    func `profile IDs survive email changes and token refreshes but separate profile homes`() {
        let one = self.profile(path: "/fixture/one", email: "one@example.test", fingerprint: "a")
        let refreshed = self.profile(path: "/fixture/one", email: "renamed@example.test", fingerprint: "b")
        let two = self.profile(path: "/fixture/two", email: "one@example.test", fingerprint: "a")
        let firstID = DashboardUsageAccount.codex(one).id
        #expect(firstID == DashboardUsageAccount.codex(refreshed).id)
        #expect(firstID != DashboardUsageAccount.codex(two).id)
        #expect(!firstID.contains("@"))
        #expect(!firstID.contains("/fixture"))
        #expect(firstID.count == "codex:".count + 64)
        let tokenID = UUID()
        let initial = self.token(id: tokenID, label: "before@example.test", token: "old")
        let renewed = self.token(id: tokenID, label: "after@example.test", token: "new")
        #expect(DashboardUsageAccount.token(initial, active: false).id
            == DashboardUsageAccount.token(renewed, active: true).id)
    }

    @Test
    func `configured accounts select non first active and missing accounts use ambient fallback`() throws {
        let accounts = [self.token(), self.token()]
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .claude,
            enabled: true,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 1))])
        let selected = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        let all = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        #expect(try selected.resolvedAccounts(for: .claude, sourceMode: .web).map(\.id) == [accounts[1].id])
        #expect(try all.resolvedAccounts(for: .claude, sourceMode: .web).map(\.id) == accounts.map(\.id))
        #expect(CodexBarCLI.serveIncludesConfiguredAccounts(provider: .claude, config: config, allAccounts: true))
        #expect(!CodexBarCLI.serveIncludesConfiguredAccounts(provider: .claude, config: config, allAccounts: false))
        #expect(!CodexBarCLI.serveIncludesConfiguredAccounts(provider: .claude, config: self.config, allAccounts: true))
        #expect(!CodexBarCLI.serveIncludesConfiguredAccounts(provider: .codex, config: self.config, allAccounts: true))
    }

    @Test
    func `default all and usage scopes cannot share provider operation fingerprints`() {
        let selected = CodexBarCLI.serveUsageOperationFingerprint(
            configFingerprint: "fixture", includeAllCodexAccounts: false)
        let usage = CodexBarCLI.serveUsageOperationFingerprint(
            configFingerprint: "fixture", includeAllCodexAccounts: true)
        let all = CodexBarCLI.serveUsageOperationFingerprint(
            configFingerprint: "fixture", includeAllCodexAccounts: true, includeAllAccounts: true)
        #expect(Set([selected, usage, all]).count == 3)
    }

    @Test
    func `warm response cache keeps account scopes separate`() async throws {
        let cache = CLIServeResponseCache()
        for allAccounts in [false, true, false, true] {
            let key = try CodexBarCLI.serveDashboardOperationKey(
                identityMode: .redacted, usageBarsShowUsed: false, provider: "codex", allAccounts: allAccounts)
            let expected = Data((allAccounts ? "all" : "selected").utf8)
            let response = await CodexBarCLI.cachedServeResponse(
                key: key, cache: cache, refreshInterval: 60, configFingerprint: "fixture")
            {
                CLILocalHTTPResponse(status: .ok, body: expected)
            }
            #expect(response.body == expected)
        }
        #expect(await cache.cachedEntryCount() == 2)
    }

    @Test(arguments: [false, true])
    func `claude swap remains the authoritative account source`(allAccounts: Bool) throws {
        let adapter = ClaudeSwapAccountProjection.accountSnapshots(from: ClaudeSwapAccountList(
            activeAccountNumber: 7,
            accounts: [ClaudeSwapAccountRow(
                number: 7,
                email: "swap@example.test",
                isActive: true,
                usageStatus: .ok,
                fiveHour: nil,
                sevenDay: nil)]))
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.payload(provider: .claude, id: "token", active: true)],
            costPayloads: [],
            config: self.config,
            identityMode: .full,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            claudeSwap: DashboardClaudeSwapInput(accounts: adapter, adapterError: nil, weeklyWorkDays: nil),
            allAccounts: allAccounts)
        let account = try #require(snapshot.providers.first?.accounts?.first)
        #expect(account.id != "token")
        #expect(account.identity?.accountEmail == "swap@example.test")
    }

    @Test
    func `managed account public ID survives promotion to live system`() {
        let storedID = UUID()
        func account(source: CodexActiveSource, storedID: UUID?) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: "private",
                email: "fixture@example.test",
                workspaceAccountID: "workspace",
                storedAccountID: storedID,
                selectionSource: source,
                isActive: true,
                isLive: source == .liveSystem,
                canReauthenticate: true,
                canRemove: true)
        }
        let managed = account(source: .managedAccount(id: storedID), storedID: storedID)
        let live = account(source: .liveSystem, storedID: storedID)
        #expect(DashboardUsageAccount.codex(managed).id == DashboardUsageAccount.codex(live).id)
        let profile = account(source: .profileHome(path: "/fixture/separate"), storedID: storedID)
        #expect(DashboardUsageAccount.codex(profile).id != DashboardUsageAccount.codex(live).id)
        let unmanaged = account(source: .liveSystem, storedID: nil)
        #expect(DashboardUsageAccount.codex(unmanaged).id != DashboardUsageAccount.codex(live).id)
    }

    @Test(arguments: [false, true])
    func `account collector preserves finished siblings at deadline for every joined waiter`(
        expanded: Bool) async throws
    {
        let timer = DashboardAccountTestGate()
        let slowStarted = DashboardAccountTestGate()
        let slowRelease = DashboardAccountTestGate()
        let now = ContinuousClock().now
        let operations = CLIServeOperationCoordinator<UsageCommandOutput>(
            now: { now },
            sleepUntil: { _ in await timer.wait() })
        let first = self.payload(id: "one", active: false, used: 10)
        let second = self.payload(id: "two", active: true, used: 65)
        let accounts = [first.dashboardAccount, second.dashboardAccount]
        let deadline = now.advanced(by: .seconds(30))
        let leader = Task {
            await CodexBarCLI.serveCollectUsageOutputs(
                providers: [.codex],
                configFingerprint: "fixture",
                deadline: deadline,
                operations: operations)
            { provider, publish in
                await CodexBarCLI.collectAccountUsage(
                    provider: provider,
                    accounts: accounts,
                    publishPartial: expanded ? publish : nil)
                { index in
                    if index == 1 {
                        await slowStarted.open()
                        // Deliberately ignores cancellation, like an in-flight provider transport.
                        await slowRelease.wait()
                    }
                    return UsageCommandOutput(payload: [index == 0 ? first : second])
                }
            }
        }
        await slowStarted.wait()
        let follower = Task {
            await CodexBarCLI.serveCollectUsageOutputs(
                providers: [.codex],
                configFingerprint: "fixture",
                deadline: deadline,
                operations: operations)
            { _ in
                Issue.record("A joined request must not start another account fetch")
                return UsageCommandOutput()
            }
        }
        for _ in 0..<10000 {
            if await operations.snapshot().waiterCount == 2 { break }
            await Task.yield()
        }
        #expect(await operations.snapshot().waiterCount == 2)
        await timer.open()
        let outputs = await [leader.value, follower.value]
        #expect(await operations.snapshot().operationCount == 1)
        let changedConfig = await CodexBarCLI.serveCollectUsageOutputs(
            providers: [.codex],
            configFingerprint: "different-account-configuration",
            deadline: deadline.advanced(by: .seconds(30)),
            operations: operations)
        { _ in
            Issue.record("A new configuration must not overlap the retained source")
            return UsageCommandOutput()
        }
        #expect(changedConfig.payload.count == 1)
        #expect(changedConfig.payload.first?.dashboardAccount == nil)
        #expect(changedConfig.payload.first?.usage == nil)
        // Drain owned source work before assertions that can throw.
        await slowRelease.open()
        for _ in 0..<10000 {
            if await operations.snapshot().operationCount == 0 { break }
            await Task.yield()
        }
        #expect(await operations.snapshot().operationCount == 0)
        for output in outputs {
            if expanded {
                #expect(output.payload.count == 2)
                #expect(output.payload.first?.usage?.primary?.usedPercent == 10)
                #expect(output.payload.first?.cacheAccountKey == "private:one@example.test")
                #expect(output.payload.last?.dashboardAccount?.id == "two")
                #expect(output.payload.last?.error != nil)
                #expect(output.payload.last?.cacheAccountKey == nil)
                let snapshot = self.snapshot(output.payload, mode: .redacted)
                let row = try #require(snapshot.providers.first)
                #expect(row.accounts?.count == 2)
                #expect(row.accounts?.first?.windows.first?.usedPercent == 10)
                #expect(row.accounts?.last?.active == true)
                #expect(row.error != nil)
            } else {
                #expect(output.payload.count == 1)
                #expect(output.payload.first?.usage == nil)
                #expect(output.payload.first?.dashboardAccount == nil)
                #expect(output.payload.first?.error != nil)
            }
        }
    }

    private var config: CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)])
    }

    private func snapshot(
        _ payloads: [ProviderPayload],
        mode: DashboardIdentityMode = .full,
        allAccounts: Bool = true) -> DashboardSnapshotPayload
    {
        DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: payloads,
            costPayloads: [],
            config: self.config,
            identityMode: mode,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            allAccounts: allAccounts)
    }

    private func payload(
        provider: UsageProvider = .codex,
        id: String,
        active: Bool,
        used: Double = 0,
        error: String? = nil) -> ProviderPayload
    {
        let email = "\(id)@example.test"
        var payload = ProviderPayload(
            provider: provider,
            account: email,
            cacheAccountKey: "private:\(email)",
            version: nil,
            source: "fixture",
            status: nil,
            usage: error == nil ? UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                identity: ProviderIdentitySnapshot(
                    providerID: provider.instanceID,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "pro")) : nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: error.map { ProviderErrorPayload(code: 1, message: $0, kind: .provider) })
        payload.dashboardAccount = DashboardUsageAccount(id: id, label: email, active: active)
        return payload
    }

    private func profile(path: String, email: String, fingerprint: String) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: "private-\(email)",
            email: email,
            workspaceAccountID: "same-workspace",
            authFingerprint: String(repeating: fingerprint, count: 64),
            storedAccountID: nil,
            selectionSource: .profileHome(path: path),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    private func token(
        id: UUID = UUID(),
        label: String = "Fixture",
        token: String = "synthetic") -> ProviderTokenAccount
    {
        ProviderTokenAccount(id: id, label: label, token: token, addedAt: 0, lastUsed: nil)
    }
}

private actor DashboardAccountTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
