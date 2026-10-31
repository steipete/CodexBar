import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardProviderWarningsTests {
    private static let notice = "Per-model breakdown unavailable (rate limited until 2:32pm)"

    @Test
    func `claude breakdown notice becomes a dashboard warning while quotas stay intact`() throws {
        let row = try #require(self.snapshot(self.payload(notice: Self.notice)).providers.first)
        #expect(row.warnings == [
            DashboardWarningPayload(code: "model-breakdown-unavailable", message: Self.notice),
        ])
        #expect(row.windows.first?.usedPercent == 25)
        #expect(row.error == nil)

        let json = try self.json(row)
        #expect(json.contains(#""warnings":[{"code":"model-breakdown-unavailable""#))
    }

    @Test
    func `rows without a partial-data notice keep their existing shape`() throws {
        let row = try #require(self.snapshot(self.payload(notice: nil)).providers.first)
        #expect(row.warnings == nil)
        #expect(try !self.json(row).contains("warnings"))
    }

    @Test
    func `same detail row id from another provider is not treated as a claude warning`() throws {
        let payload = try self.payload(provider: .codex, notice: Self.notice)
        let row = try #require(self.snapshot(payload).providers.first)
        #expect(row.warnings == nil)
    }

    @Test
    func `shell detail omits warnings`() throws {
        let shell = DashboardProviderPayload(
            id: "claude",
            name: "Claude",
            enabled: true,
            source: "",
            status: nil,
            identity: nil,
            windows: [],
            credits: nil,
            cost: nil,
            display: DashboardDisplayPayload(accentColor: "#000000", sortKey: 0, priority: "normal"),
            error: nil,
            updatedAt: nil,
            accounts: nil,
            accountsError: nil,
            warnings: [DashboardWarningPayload(code: "model-breakdown-unavailable", message: Self.notice)],
            detail: .shell)
        #expect(try !self.json(shell).contains("warnings"))
    }

    private func json(_ row: DashboardProviderPayload) throws -> String {
        try #require(String(data: JSONEncoder().encode(row), encoding: .utf8))
    }

    private func snapshot(_ payload: ProviderPayload) -> DashboardSnapshotPayload {
        DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: []),
            identityMode: .none,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil)
    }

    private func payload(provider: UsageProvider = .claude, notice: String?) throws -> ProviderPayload {
        let details = try notice.map { notice in
            try [
                ProviderDetailSection(rows: [
                    ProviderDetailSection.Row(
                        id: ClaudeStatusProbe.modelBreakdownDetailRowID,
                        label: "Status",
                        value: notice),
                ]),
            ]
        } ?? []
        return ProviderPayload(
            provider: provider,
            account: nil,
            version: nil,
            source: "cli",
            status: nil,
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                details: details,
                updatedAt: Date(timeIntervalSince1970: 0)),
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }
}
