import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardLimitResetCreditsTests {
    @Test
    func `dashboard provider projects codex limit reset credits with next expiry`() throws {
        let now = Date()
        let expiresSoon = now.addingTimeInterval(3_600)
        let expiresLater = now.addingTimeInterval(7_200)
        let usage = UsageSnapshot(
            primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: [
                    self.availableResetCredit(id: "later", expiresAt: expiresLater),
                    self.availableResetCredit(id: "expired", expiresAt: now.addingTimeInterval(-60)),
                    self.availableResetCredit(id: "soon", expiresAt: expiresSoon),
                ],
                availableCount: 2,
                updatedAt: now),
            updatedAt: now)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.codexPayload(usage: usage)],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .full,
            generatedAt: now,
            refreshInterval: 0,
            codexBarVersion: nil)

        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let limitResetCredits = try #require(provider["limitResetCredits"] as? [String: Any])

        #expect(limitResetCredits["available"] as? Int == 2)
        #expect(limitResetCredits["nextExpiresAt"] as? String == self.iso8601(expiresSoon))
    }

    @Test
    func `dashboard provider omits limit reset credits when the usage snapshot has none`() throws {
        let now = Date()
        let usage = UsageSnapshot(
            primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.codexPayload(usage: usage)],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]),
            identityMode: .full,
            generatedAt: now,
            refreshInterval: 0,
            codexBarVersion: nil)

        let object = try self.jsonObject(snapshot)
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)

        #expect(provider["limitResetCredits"] == nil)
    }

    private func codexPayload(usage: UsageSnapshot) -> ProviderPayload {
        ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "oauth",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func availableResetCredit(id: String, expiresAt: Date?) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: Date(timeIntervalSince1970: 0),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func jsonObject(_ payload: some Encodable) throws -> [String: Any] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
