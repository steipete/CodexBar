import Foundation
import Testing
@testable import CodexBarCore

struct WidgetSnapshotCompatibilityTests {
    @Test
    func `pre account JSON preserves provider quotas costs and display preferences`() throws {
        let snapshot = try self.decoder().decode(WidgetSnapshot.self, from: Data(Self.legacyJSON.utf8))

        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.enabledProviders == [.claude, .codex])
        #expect(snapshot.usageBarsShowUsed)
        let claude = try #require(snapshot.entries.first { $0.provider == .claude })
        #expect(claude.accountLabel == nil)
        #expect(claude.primary?.remainingPercent == 75)
        #expect(claude.secondary?.remainingPercent == 60)
        #expect(claude.usageRows?.map(\.id) == ["session", "weekly"])
        #expect(claude.quotaOwnerKey == "fixture-claude-owner")
        #expect(claude.updatedAt == snapshot.generatedAt)
        let codex = try #require(snapshot.selectingAccount(nil, for: .codex).entries.first { $0.provider == .codex })
        #expect(codex.primary?.remainingPercent == 90)
        #expect(codex.creditsRemaining == 12.5)
        #expect(codex.tokenUsage?.sessionCostUSD == 1.25)
        #expect(codex.tokenUsage?.currencyCode == "USD")
        #expect(codex.dailyUsage.first?.totalTokens == 1200)
        #expect(codex.accountLabel == nil)
    }

    @Test
    func `older provider snapshot defaults survive without new account fields`() throws {
        let data = Data(#"""
        {
          "entries": [{
            "provider": "claude", "updatedAt": "2025-12-20T12:00:00Z",
            "primary": {"usedPercent": 25}, "dailyUsage": []
          }],
          "generatedAt": "2025-12-20T12:00:00Z"
        }
        """#.utf8)
        let snapshot = try self.decoder().decode(WidgetSnapshot.self, from: data)

        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.enabledProviders == [.claude])
        #expect(!snapshot.usageBarsShowUsed)
        #expect(snapshot.selectingAccount(nil, for: .claude).entries.first?.primary?.remainingPercent == 75)
        #expect(snapshot.entries.first?.accountLabel == nil)
    }

    @Test
    func `legacy reader ignores account additions and a rollback write remains readable`() throws {
        let old = try self.decoder().decode(WidgetSnapshot.self, from: Data(Self.legacyJSON.utf8))
        let accountUsage = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: old.generatedAt,
            primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            accountLabel: "Work")
        let snapshot = WidgetSnapshot(
            entries: [accountUsage] + old.entries.filter { $0.provider == .codex },
            accounts: [
                .init(id: "claude/token:work", provider: .claude, label: "Work", usage: accountUsage),
                .init(id: "claude/token:unavailable", provider: .claude, label: "Personal", usage: nil),
            ],
            enabledProviders: old.enabledProviders,
            usageBarsShowUsed: old.usageBarsShowUsed,
            generatedAt: old.generatedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try self.decoder().decode(LegacyWidgetSnapshot.self, from: encoder.encode(snapshot))

        #expect(legacy.entries.map(\.provider) == [.claude, .codex])
        #expect(legacy.entries.first?.primary?.remainingPercent == 20)
        #expect(legacy.entries.last?.creditsRemaining == 12.5)
        #expect(legacy.entries.last?.tokenUsage?.sessionTokens == 1200)
        #expect(legacy.enabledProviders == snapshot.enabledProviders)
        #expect(legacy.generatedAt == snapshot.generatedAt)
        #expect(legacy.usageBarsShowUsed)

        let rewritten = try self.decoder().decode(WidgetSnapshot.self, from: encoder.encode(legacy))
        #expect(rewritten.accounts.isEmpty)
        #expect(rewritten.entries.allSatisfy { $0.accountLabel == nil })
        #expect(rewritten.selectingAccount(nil, for: .claude).entries.first?.primary?.remainingPercent == 20)
        #expect(!rewritten.selectingAccount("claude/token:work", for: .claude).entries.contains {
            $0.provider == .claude
        })
    }

    @Test
    func `an account record cannot substitute quota from a different provider`() throws {
        let old = try self.decoder().decode(WidgetSnapshot.self, from: Data(Self.legacyJSON.utf8))
        let codex = try #require(old.entries.first { $0.provider == .codex })
        let snapshot = WidgetSnapshot(
            entries: old.entries,
            accounts: [.init(id: "claude/token:work", provider: .claude, label: "Work", usage: codex)],
            enabledProviders: old.enabledProviders,
            generatedAt: old.generatedAt)
        let selected = snapshot.selectingAccount("claude/token:work", for: .claude)

        #expect(!selected.entries.contains { $0.provider == .claude })
        #expect(selected.entries.first?.provider == .codex)
        #expect(selected.entries.first?.primary?.remainingPercent == 90)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Fixed pre-feature wire data, independent of the current WidgetSnapshot encoder.
    private static let legacyJSON = #"""
    {
      "entries": [
        {
          "provider": "claude",
          "updatedAt": "2025-12-20T12:00:00Z",
          "primary": {"usedPercent": 25, "windowMinutes": 300, "resetsAt": "2025-12-20T15:00:00Z"},
          "secondary": {"usedPercent": 40, "windowMinutes": 10080, "resetsAt": "2025-12-25T12:00:00Z"},
          "usageRows": [
            {"id": "session", "title": "Session", "percentLeft": 75},
            {"id": "weekly", "title": "Weekly", "percentLeft": 60}
          ],
          "dailyUsage": [],
          "quotaOwnerKey": "fixture-claude-owner"
        },
        {
          "provider": "codex",
          "updatedAt": "2025-12-20T12:00:00Z",
          "primary": {"usedPercent": 10, "windowMinutes": 300, "resetsAt": "2025-12-20T16:00:00Z"},
          "secondary": {"usedPercent": 20, "windowMinutes": 10080, "resetsAt": "2025-12-26T12:00:00Z"},
          "creditsRemaining": 12.5,
          "codeReviewRemainingPercent": 85,
          "tokenUsage": {
            "sessionCostUSD": 1.25,
            "sessionTokens": 1200,
            "last30DaysCostUSD": 19.5,
            "last30DaysTokens": 18000,
            "currencyCode": "USD",
            "sessionLabel": "Today",
            "last30DaysLabel": "30d",
            "updatedAt": "2025-12-20T11:55:00Z"
          },
          "dailyUsage": [{"dayKey": "2025-12-20", "totalTokens": 1200, "costUSD": 1.25}]
        }
      ],
      "enabledProviders": ["claude", "codex"],
      "usageBarsShowUsed": true,
      "generatedAt": "2025-12-20T12:00:00Z"
    }
    """#
}

/// Freeze the pre-account wire fields here: using WidgetSnapshot itself as the old reader
/// would stop detecting accidental required-field additions or changes to provider entries.
private struct LegacyWidgetSnapshot: Codable {
    let entries: [LegacyWidgetProviderEntry]
    let enabledProviders: [ProviderInstanceID]
    let usageBarsShowUsed: Bool
    let generatedAt: Date
}

private struct LegacyWidgetProviderEntry: Codable {
    let provider: ProviderInstanceID
    let updatedAt: Date
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let usageRows: [WidgetSnapshot.WidgetUsageRowSnapshot]?
    let creditsRemaining: Double?
    let codeReviewRemainingPercent: Double?
    let tokenUsage: WidgetSnapshot.TokenUsageSummary?
    let dailyUsage: [WidgetSnapshot.DailyUsagePoint]
    let providerCost: ProviderCostSnapshot?
    let quotaOwnerKey: String?
}
