import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct WidgetAccountSnapshotTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `disabled providers cannot render retained account snapshots`() {
        let entry = self.entry(left: 15)
        let snapshot = WidgetSnapshot(
            entries: [entry],
            accounts: [.init(id: "work", provider: .claude, label: "Work", usage: entry)],
            enabledProviders: [],
            generatedAt: self.date)
        #expect(snapshot.selectingAccount("work", for: .claude).entries.isEmpty)
    }

    @Test
    func `two widgets select different accounts without changing the provider default`() {
        let first = self.entry(left: 15, label: "Work")
        let second = self.entry(left: 90, label: "Personal")
        let snapshot = self.snapshot(first: first, second: second)

        let work = snapshot.selectingAccount("claude/token:work", for: .claude)
        let personal = snapshot.selectingAccount("claude/token:personal", for: .claude)
        #expect(work.entries.first?.primary?.remainingPercent == 15)
        #expect(personal.entries.first?.primary?.remainingPercent == 90)
        #expect(snapshot.entries.first?.primary?.remainingPercent == 15)
        #expect(snapshot.selectingAccount(nil, for: .claude).entries.first?.accountLabel == "Work")
        #expect(personal.entries.first?.updatedAt == self.date)
    }

    @Test
    func `unknown removed and cross provider selections never fall back to active usage`() {
        let snapshot = self.snapshot(first: self.entry(left: 15), second: nil)
        #expect(snapshot.selectingAccount("removed", for: .claude).entries.isEmpty)
        #expect(snapshot.selectingAccount("claude/token:personal", for: .claude).entries.isEmpty)
        let other = snapshot.selectingAccount("claude/token:work", for: .codex)
        #expect(!other.entries.contains { $0.provider == .codex })
        #expect(other.entries.first?.provider == .claude)
    }

    @Test
    func `account snapshots round trip and preserve unavailable identities`() throws {
        let snapshot = self.snapshot(first: self.entry(left: 15, label: "Work"), second: nil)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.accounts.map(\.id) == snapshot.accounts.map(\.id))
        #expect(decoded.accounts.first?.usage?.accountLabel == "Work")
        #expect(decoded.accounts.last?.usage == nil)
    }

    @Test
    func `legacy provider snapshots decode with no account picker choices`() throws {
        let original = WidgetSnapshot(entries: [self.entry(left: 25)], generatedAt: self.date)
        let data = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "accounts")
        let legacy = try JSONDecoder().decode(
            WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.accounts.isEmpty)
        #expect(legacy.selectingAccount(nil, for: .claude).entries.first?.primary?.remainingPercent == 25)
    }

    private func entry(left: Double, label: String? = nil) -> WidgetSnapshot.ProviderEntry {
        WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: self.date,
            primary: RateWindow(usedPercent: 100 - left, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            accountLabel: label)
    }

    private func snapshot(
        first: WidgetSnapshot.ProviderEntry,
        second: WidgetSnapshot.ProviderEntry?) -> WidgetSnapshot
    {
        WidgetSnapshot(
            entries: [first],
            accounts: [
                .init(id: "claude/token:work", provider: .claude, label: "Work", usage: first),
                .init(id: "claude/token:personal", provider: .claude, label: "Personal", usage: second),
            ],
            generatedAt: self.date)
    }
}

@MainActor
struct WidgetAccountPublicationTests {
    @Test
    func `profile paths and personal identities are not persisted in widget identifiers`() {
        let first = UsageStore.widgetOpaqueAccountID("profile:/Users/fixture/private-account")
        #expect(first == UsageStore.widgetOpaqueAccountID("profile:/Users/fixture/private-account"))
        #expect(first != UsageStore.widgetOpaqueAccountID("profile:/Users/fixture/other-account"))
        #expect(!first.contains("fixture"))
        #expect(first.count == 64)
    }

    @Test
    func `account widget opt in refreshes segmented accounts and keeps their quotas isolated`() throws {
        let (settings, store) = self.makeStore()
        settings.accountWidgetsEnabled = true
        settings.multiAccountMenuLayout = .segmented
        let accounts = settings.tokenAccounts(for: .claude)
        #expect(store.shouldFetchAllTokenAccounts(provider: .claude, accounts: accounts))
        store.accountSnapshots[.claude] = accounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.usage(percent: Double(index * 60)),
                error: nil,
                sourceLabel: "fixture",
                cacheKey: store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
        }
        let result = store.makeWidgetAccountEntries(now: Date())
        #expect(result.count == 2)
        #expect(result.map { $0.usage?.primary?.usedPercent } == [0, 60])
        #expect(result.allSatisfy { $0.usage?.tokenUsage == nil && $0.usage?.dailyUsage.isEmpty == true })
        #expect(result.allSatisfy { $0.usage?.creditsRemaining == nil })

        settings.hidePersonalInfo = true
        let hidden = store.makeWidgetAccountEntries(now: Date())
        #expect(hidden.map(\.id) == result.map(\.id))
        #expect(hidden.map(\.label) == ["Account 1", "Account 2"])
        let encoded = try #require(String(data: JSONEncoder().encode(hidden), encoding: .utf8))
        #expect(!encoded.contains("Work"))
        #expect(!encoded.contains("Personal"))
        #expect(!encoded.contains("fixture-token"))
    }

    @Test
    func `off by default does not publish identities or fan out segmented refreshes`() {
        let (settings, store) = self.makeStore()
        settings.multiAccountMenuLayout = .segmented
        #expect(!settings.accountWidgetsEnabled)
        #expect(store.makeWidgetAccountEntries(now: Date()).isEmpty)
        #expect(!store.shouldFetchAllTokenAccounts(provider: .claude, accounts: settings.tokenAccounts(for: .claude)))
    }

    @Test
    func `invalid account cache never publishes under a newly configured credential`() {
        let (settings, store) = self.makeStore()
        settings.accountWidgetsEnabled = true
        let account = settings.tokenAccounts(for: .claude)[0]
        store.accountSnapshots[.claude] = [TokenAccountUsageSnapshot(
            account: account, snapshot: self.usage(percent: 10), error: nil, sourceLabel: nil, cacheKey: "obsolete")]
        let result = store.makeWidgetAccountEntries(now: Date())
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.usage == nil })
    }

    private func makeStore() -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "WidgetAccountPublicationTests-\(UUID().uuidString)")
        settings.providerDetectionCompleted = true
        settings.setProviderEnabled(provider: .claude, metadata: ProviderDefaults.metadata[.claude]!, enabled: true)
        settings.setProviderEnabled(provider: .codex, metadata: ProviderDefaults.metadata[.codex]!, enabled: false)
        settings.addTokenAccount(provider: .claude, label: "Work", token: "fixture-token-work")
        settings.addTokenAccount(provider: .claude, label: "Personal", token: "fixture-token-personal")
        return (settings, UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:]))
    }

    private func usage(percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: percent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
