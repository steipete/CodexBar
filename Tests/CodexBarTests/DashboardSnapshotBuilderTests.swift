import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardSnapshotBuilderTests {
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
