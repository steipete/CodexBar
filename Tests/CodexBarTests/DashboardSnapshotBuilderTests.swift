import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardSnapshotBuilderTests {
    @Test
    func `builds stable display-oriented dashboard snapshot`() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_010)
        let resetAt = Date(timeIntervalSince1970: 1_800_003_600)
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
            updatedAt: updatedAt,
            sessionTokens: 1000,
            sessionCostUSD: 1.04,
            historyDays: 30,
            last30DaysTokens: 30000,
            last30DaysCostUSD: 18.22,
            daily: [],
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
        #expect(provider["updatedAt"] as? String == "2027-01-15T08:00:10Z")

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

    private func jsonObject(_ payload: some Encodable) throws -> [String: Any] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
