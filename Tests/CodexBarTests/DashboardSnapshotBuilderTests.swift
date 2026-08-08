import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardSnapshotBuilderTests {
    @Test
    func `dashboard cost collection does not fetch Cursor when cookie source is off`() async {
        let recorder = DashboardCostFetchRecorder()
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .cursor, enabled: true, cookieSource: .off),
        ])

        let payload = await CodexBarCLI.collectConfiguredCostPayloads(
            providers: [.cursor],
            config: config,
            context: self.costCollectionContext())
        { provider, header in
            await recorder.record(provider: provider, cursorCookieHeaderOverride: header)
            return CodexBarCLI.makeCostPayload(provider: provider, snapshot: nil, error: nil)
        }

        #expect(await recorder.calls().isEmpty)
        #expect(payload.count == 1)
        #expect(payload[0].provider == "cursor")
        #expect(payload[0].error?.message.contains("cookie source is set to Off") == true)
    }

    @Test
    func `dashboard cost collection forwards configured Cursor manual cookie`() async {
        let recorder = DashboardCostFetchRecorder()
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .cursor,
                enabled: true,
                cookieHeader: "  session=manual  ",
                cookieSource: .manual),
        ])

        let payload = await CodexBarCLI.collectConfiguredCostPayloads(
            providers: [.cursor],
            config: config,
            context: self.costCollectionContext())
        { provider, header in
            await recorder.record(provider: provider, cursorCookieHeaderOverride: header)
            return CodexBarCLI.makeCostPayload(provider: provider, snapshot: nil, error: nil)
        }

        let calls = await recorder.calls()
        #expect(calls.count == 1)
        #expect(calls[0].provider == .cursor)
        #expect(calls[0].cursorCookieHeaderOverride == "session=manual")
        #expect(payload.count == 1)
        #expect(payload[0].error == nil)
    }

    @Test
    func `dashboard producer forwards its config to cost collection`() async throws {
        let recorder = DashboardCostConfigRecorder()
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .cursor,
                enabled: true,
                cookieHeader: "session=manual",
                cookieSource: .manual),
        ])
        let producer = DashboardSnapshotProducer(
            collectUsage: { _ in UsageCommandOutput() },
            collectCost: { providers, config in
                await recorder.record(providers: providers, config: config)
                return []
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })

        _ = try await producer.collect(
            config: config,
            refreshInterval: 0,
            codexBarVersion: "9.8.7")

        let call = try #require(await recorder.call())
        #expect(call.providers == [.cursor])
        #expect(call.cookieSource == .manual)
        #expect(call.cookieHeader == "session=manual")
    }

    @Test
    func `producer defaults to full identity and keeps stable order and partial errors`() async throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = self.identityPayload(email: "user@example.com")
        let failed = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "auto",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: 1, message: "temporary failure", kind: .provider))
        let rows: [UsageProvider: ProviderPayload] = [.claude: healthy, .codex: failed]
        let producer = DashboardSnapshotProducer(
            collectUsage: { providers in
                var output = UsageCommandOutput()
                output.payload = providers.compactMap { rows[$0] }
                output.exitCode = .failure
                return output
            },
            collectCost: { _, _ in [] },
            now: { generatedAt })
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .claude, enabled: true),
            ProviderConfig(id: .codex, enabled: true),
        ])

        let result = try await producer.collect(
            config: config,
            refreshInterval: 0,
            codexBarVersion: "9.8.7")
        let object = try self.jsonObject(result.payload)
        let providers = try #require(object["providers"] as? [[String: Any]])
        let error = try #require(providers[0]["error"] as? [String: Any])
        let identity = try #require(providers[1]["identity"] as? [String: Any])
        let codexDisplay = try #require(providers[0]["display"] as? [String: Any])
        let claudeDisplay = try #require(providers[1]["display"] as? [String: Any])

        #expect(providers.compactMap { $0["id"] as? String } == ["codex", "claude"])
        #expect(identity["accountEmail"] as? String == "user@example.com")
        #expect(error["message"] as? String == "temporary failure")
        #expect(codexDisplay["sortKey"] as? Int == 10)
        #expect(claudeDisplay["sortKey"] as? Int == 0)
        #expect(object["generatedAt"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test
    func `producer provider filter collects and returns exactly one row`() async throws {
        let recorder = DashboardProviderSelectionRecorder()
        let producer = DashboardSnapshotProducer(
            collectUsage: { providers in
                await recorder.recordUsage(providers)
                var output = UsageCommandOutput()
                output.payload = providers.map { provider in
                    ProviderPayload(
                        provider: provider,
                        account: nil,
                        version: nil,
                        source: "test",
                        status: nil,
                        usage: nil,
                        credits: nil,
                        antigravityPlanInfo: nil,
                        openaiDashboard: nil,
                        error: nil)
                }
                return output
            },
            collectCost: { providers, _ in
                await recorder.recordCost(providers)
                return []
            },
            now: { Date(timeIntervalSince1970: 0) })
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .claude, enabled: true),
            ProviderConfig(id: .codex, enabled: true),
        ])

        let result = try await producer.collect(
            config: config,
            refreshInterval: 60,
            codexBarVersion: nil,
            providers: [.codex])
        let object = try self.jsonObject(result.payload)
        let providers = try #require(object["providers"] as? [[String: Any]])

        #expect(providers.compactMap { $0["id"] as? String } == ["codex"])
        #expect(await recorder.usageProviders() == [.codex])
        #expect(await recorder.costProviders() == [.codex])
    }

    @Test
    func `shell builder emits config fields only without fetch collaborators`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .claude, enabled: true),
            ProviderConfig(id: .codex, enabled: true),
            ProviderConfig(id: .gemini, enabled: false),
        ])
        let snapshot = DashboardSnapshotBuilder.makeShellSnapshot(
            config: config,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 300,
            codexBarVersion: "9.8.7")
        let object = try self.jsonObject(snapshot)
        let providers = try #require(object["providers"] as? [[String: Any]])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(providers.compactMap { $0["id"] as? String } == ["claude", "codex"])
        #expect(providers.allSatisfy { Set($0.keys) == ["id", "name", "enabled", "display"] })
        #expect((providers[0]["display"] as? [String: Any])?["sortKey"] as? Int == 0)
        #expect((providers[1]["display"] as? [String: Any])?["sortKey"] as? Int == 10)
    }

    private func costCollectionContext() -> ServeCostCollectionContext {
        ServeCostCollectionContext(
            configFingerprint: "dashboard-cost-policy",
            providerTimeout: nil,
            requestDeadline: nil,
            now: { ContinuousClock().now },
            providerOperations: CLIServeOperationCoordinator())
    }

    @Test
    func `builds stable display-oriented dashboard snapshot`() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_010)
        let costUpdatedAt = Date(timeIntervalSince1970: 1_800_000_020)
        let resetAt = Date(timeIntervalSince1970: 1_800_003_600)
        let generatedDay = self.gregorianDayKey(generatedAt)
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 28,
                windowMinutes: 300,
                resetsAt: resetAt,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 59,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "oauth",
            status: ProviderStatusPayload(
                indicator: .none,
                description: "Operational",
                updatedAt: updatedAt,
                url: "https://status.example.com"),
            usage: usage,
            credits: CreditsSnapshot(remaining: 112.4, events: [], updatedAt: updatedAt),
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let cost = CostPayload(
            provider: "codex",
            source: "local",
            updatedAt: costUpdatedAt,
            sessionTokens: 1000,
            sessionCostUSD: 1.04,
            historyDays: 30,
            last30DaysTokens: 30000,
            last30DaysCostUSD: 18.22,
            daily: [CostDailyEntryPayload(
                date: generatedDay,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 1000,
                costUSD: 1.04,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            totals: nil,
            error: nil)
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, enabled: true),
            ProviderConfig(id: .claude, enabled: false),
        ])

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [cost],
            config: config,
            identityMode: .redacted,
            generatedAt: generatedAt,
            refreshInterval: 60,
            codexBarVersion: "9.8.7")
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let host = try #require(object["host"] as? [String: Any])
        let identity = try #require(provider["identity"] as? [String: Any])
        let status = try #require(provider["status"] as? [String: Any])
        let windows = try #require(provider["windows"] as? [[String: Any]])
        let credits = try #require(provider["credits"] as? [String: Any])
        let costObject = try #require(provider["cost"] as? [String: Any])
        let display = try #require(provider["display"] as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["staleAfterSeconds"] as? Int == 180)
        #expect(host["codexBarVersion"] as? String == "9.8.7")
        #expect(host["refreshIntervalSeconds"] as? Int == 60)

        #expect(provider["id"] as? String == "codex")
        #expect(provider["name"] as? String == "Codex")
        #expect(provider["enabled"] as? Bool == true)
        #expect(provider["source"] as? String == "oauth")
        #expect(provider["error"] is NSNull)
        #expect(provider["updatedAt"] as? String == "2027-01-15T08:00:20Z")

        #expect(status["level"] as? String == "ok")
        #expect(status["label"] as? String == "Operational")
        #expect(identity["accountEmail"] as? String == "redacted@example.com")
        #expect(identity["plan"] as? String == "Pro 20x")

        #expect(windows.count == 2)
        #expect(windows[0]["kind"] as? String == "session")
        #expect(windows[0]["label"] as? String == "Session")
        #expect(windows[0]["usedPercent"] as? Double == 28)
        #expect(windows[0]["remainingPercent"] as? Double == 72)
        #expect(windows[0]["resetAt"] as? String == "2027-01-15T09:00:00Z")
        #expect(windows[1]["kind"] as? String == "weekly")
        #expect(windows[1]["label"] as? String == "Weekly")

        #expect(credits["remaining"] as? Double == 112.4)
        #expect(credits["unit"] as? String == "credits")
        #expect(costObject["todayUSD"] as? Double == 1.04)
        #expect(costObject["last30DaysUSD"] as? Double == 18.22)
        #expect(display["accentColor"] as? String == "#49A3B0")
        #expect(display["sortKey"] as? Int == 0)
        #expect(display["priority"] as? String == "normal")
    }

    @Test
    func `dashboard identity mode none emits null identity`() throws {
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))
        let payload = ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "web",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .none,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)

        #expect(provider["identity"] is NSNull)
        #expect(provider["status"] is NSNull)
        #expect(provider["credits"] is NSNull)
        #expect(provider["cost"] is NSNull)
    }

    @Test
    func `dashboard labels amp subscription pools as provider specific windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = AmpUsageSnapshot(
            freeQuota: nil,
            freeUsed: nil,
            hourlyReplenishment: nil,
            windowHours: nil,
            updatedAt: now,
            subscription: AmpSubscriptionUsage(
                plan: "Megawatt",
                otherUsedPercent: 3,
                orbUsedPercent: 0,
                resetsAt: now.addingTimeInterval(29 * 24 * 60 * 60),
                resetDescription: "renews in 29 days"))
            .toUsageSnapshot(now: now)
        let payload = ProviderPayload(
            provider: .amp,
            account: nil,
            version: nil,
            source: "cli",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .amp, enabled: true)]),
            identityMode: .redacted,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let windows = try #require(provider["windows"] as? [[String: Any]])

        #expect(windows.map { $0["kind"] as? String } == ["other", "orb"])
        #expect(windows.map { $0["label"] as? String } == ["Other usage", "Orb usage"])
    }

    @Test
    func `dashboard identity mode redacted hides local part but keeps domain`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.identityPayload(email: "user@example.com")],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)
        let domainless = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.identityPayload(email: "not-an-email")],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)

        let identity = try #require(self.firstIdentity(snapshot))
        let domainlessIdentity = try #require(self.firstIdentity(domainless))
        #expect(identity["accountEmail"] as? String == "redacted@example.com")
        #expect(domainlessIdentity["accountEmail"] as? String == "redacted")
    }

    @Test
    func `claude swap account keeps email when usage fetch fails`() throws {
        let snapshot = self.claudeSwapSnapshot(
            number: 1,
            email: "stale@example.com",
            usageStatus: .tokenExpired,
            identityMode: .full)
        let account = try self.firstClaudeSwapAccount(snapshot)
        let identity = try #require(account["identity"] as? [String: Any])

        #expect(identity["accountEmail"] as? String == "stale@example.com")
        #expect(account["label"] as? String == "stale@example.com")
        #expect((account["windows"] as? [Any])?.isEmpty == true)
    }

    @Test
    func `claude swap failed account redacts email in identity and label`() throws {
        let snapshot = self.claudeSwapSnapshot(
            number: 4,
            email: "private-person@example.com",
            usageStatus: .noCredentials,
            identityMode: .redacted)
        let account = try self.firstClaudeSwapAccount(snapshot)
        let identity = try #require(account["identity"] as? [String: Any])
        let encoded = try #require(CodexBarCLI.encodeJSON(snapshot, pretty: false))

        #expect(identity["accountEmail"] as? String == "redacted@example.com")
        #expect(account["label"] as? String == "redacted@example.com")
        #expect(!encoded.contains("private-person"))
    }

    @Test
    func `claude swap placeholder label stays a slot label without identity`() throws {
        let snapshot = self.claudeSwapSnapshot(
            number: 7,
            email: "",
            usageStatus: .unavailable,
            identityMode: .full)
        let account = try self.firstClaudeSwapAccount(snapshot)

        #expect(account["label"] as? String == "Account 7")
        #expect(account["identity"] is NSNull)
    }

    @Test
    func `dashboard redaction keeps only the final email domain`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.identityPayload(email: #""foo@bar"@example.com"#)],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)

        let identity = try #require(self.firstIdentity(snapshot))
        #expect(identity["accountEmail"] as? String == "redacted@example.com")
    }

    @Test
    func `dashboard provider errors are projected without raw usage internals`() throws {
        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "auto",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: 1, message: "temporary failure", kind: .provider))

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let error = try #require(provider["error"] as? [String: Any])

        #expect((provider["windows"] as? [Any])?.isEmpty == true)
        #expect(error["message"] as? String == "temporary failure")
        #expect(provider["usage"] == nil)
        #expect(provider["openaiDashboard"] == nil)
    }

    @Test
    func `dashboard surfaces cost failures when usage succeeds`() throws {
        let usage = self.identityPayload(email: "user@example.com")
        let cost = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 10),
            sessionTokens: nil,
            sessionCostUSD: nil,
            historyDays: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [],
            totals: nil,
            error: ProviderErrorPayload(code: 1, message: "cost unavailable", kind: .provider))

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [usage],
            costPayloads: [cost],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 20),
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let error = try #require(provider["error"] as? [String: Any])

        #expect(error["message"] as? String == "cost unavailable")
        #expect(provider["updatedAt"] as? String == "1970-01-01T00:00:10Z")
    }

    @Test
    func `dashboard provider freshness includes status updates`() throws {
        let payload = ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "status",
            status: ProviderStatusPayload(
                indicator: .none,
                description: "Operational",
                updatedAt: Date(timeIntervalSince1970: 30),
                url: "https://status.anthropic.com"),
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 40),
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)

        #expect(provider["updatedAt"] as? String == "1970-01-01T00:00:30Z")
    }

    @Test
    func `dashboard safely clamps extreme refresh intervals`() {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [],
            costPayloads: [],
            config: CodexBarConfig(providers: []),
            identityMode: .redacted,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: .greatestFiniteMagnitude,
            codexBarVersion: nil)

        #expect(snapshot.host.refreshIntervalSeconds == Int.max / 3)
        #expect(snapshot.staleAfterSeconds == (Int.max / 3) * 3)
    }

    @Test
    func `dashboard daily cost uses generation day without update metadata`() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = self.identityPayload(email: "user@example.com")
        let cost = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: nil,
            sessionTokens: nil,
            sessionCostUSD: nil,
            historyDays: 1,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [CostDailyEntryPayload(
                date: self.gregorianDayKey(generatedAt),
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: nil,
                costUSD: 2.5,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            totals: nil,
            error: nil)

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [usage],
            costPayloads: [cost],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: .redacted,
            generatedAt: generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let costObject = try #require(provider["cost"] as? [String: Any])

        #expect(costObject["todayUSD"] as? Double == 2.5)
    }

    private func identityPayload(email: String) -> ProviderPayload {
        ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "web",
            status: nil,
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "pro")),
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func claudeSwapSnapshot(
        number: Int,
        email: String,
        usageStatus: ClaudeSwapUsageStatus,
        identityMode: DashboardIdentityMode) -> DashboardSnapshotPayload
    {
        // Provider-specific by design: these fixtures cover claude-swap labels without usage snapshots.
        let account = ClaudeSwapAccountProjection.accountSnapshots(from: ClaudeSwapAccountList(
            activeAccountNumber: number,
            accounts: [ClaudeSwapAccountRow(
                number: number,
                email: email,
                isActive: true,
                usageStatus: usageStatus,
                fiveHour: nil,
                sevenDay: nil)]))
        return DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.identityPayload(email: "ambient@example.com")],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]),
            identityMode: identityMode,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            claudeSwap: DashboardClaudeSwapInput(accounts: account, adapterError: nil, weeklyWorkDays: nil))
    }

    private func firstClaudeSwapAccount(_ snapshot: DashboardSnapshotPayload) throws -> [String: Any] {
        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        return try #require((provider["accounts"] as? [[String: Any]])?.first)
    }

    private func firstIdentity(_ snapshot: DashboardSnapshotPayload) -> [String: Any]? {
        guard let object = try? self.jsonObject(snapshot) else { return nil }
        let provider = (object["providers"] as? [[String: Any]])?.first
        return provider?["identity"] as? [String: Any]
    }

    private func gregorianDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    private func jsonObject(_ payload: some Encodable) throws -> [String: Any] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor DashboardCostFetchRecorder {
    struct Call: Sendable {
        let provider: UsageProvider
        let cursorCookieHeaderOverride: String?
    }

    private var recordedCalls: [Call] = []

    func record(provider: UsageProvider, cursorCookieHeaderOverride: String?) {
        self.recordedCalls.append(Call(
            provider: provider,
            cursorCookieHeaderOverride: cursorCookieHeaderOverride))
    }

    func calls() -> [Call] {
        self.recordedCalls
    }
}

private actor DashboardCostConfigRecorder {
    struct Call: Sendable {
        let providers: [UsageProvider]
        let cookieSource: ProviderCookieSource?
        let cookieHeader: String?
    }

    private var recordedCall: Call?

    func record(providers: [UsageProvider], config: CodexBarConfig) {
        let cursor = config.providerConfig(for: .cursor)
        self.recordedCall = Call(
            providers: providers,
            cookieSource: cursor?.cookieSource,
            cookieHeader: cursor?.cookieHeader)
    }

    func call() -> Call? {
        self.recordedCall
    }
}

private actor DashboardProviderSelectionRecorder {
    private var usage: [UsageProvider] = []
    private var cost: [UsageProvider] = []

    func recordUsage(_ providers: [UsageProvider]) {
        self.usage = providers
    }

    func recordCost(_ providers: [UsageProvider]) {
        self.cost = providers
    }

    func usageProviders() -> [UsageProvider] {
        self.usage
    }

    func costProviders() -> [UsageProvider] {
        self.cost
    }
}
