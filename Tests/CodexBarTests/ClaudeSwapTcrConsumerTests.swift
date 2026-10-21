import CodexBarCore
import CryptoKit
import Foundation
import Testing
@testable import CodexBar

/// tcr accounts reach the same menu, privacy and widget consumers as claude-swap
/// accounts. Each consumer must keep the account's own source, and claude-swap
/// identities written before tcr existed must keep their exact bytes.
@MainActor
struct ClaudeSwapTcrConsumerTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    // MARK: Menu card source

    @Test
    func `tcr menu cards carry the tcr source and keep the decorated label`() throws {
        let (settings, store) = self.makeStore()
        let accounts = try self.tcrAccounts()
        let carol = try #require(accounts.first { $0.id.opaqueID == "3" })
        #expect(carol.displayLabel == "carol@example.com (disabled)")

        let context = ClaudeSwapAccountMenuDisplay.cardContext(
            for: carol,
            planLabel: nil,
            adapterError: nil,
            switchError: nil)
        #expect(context.account?.sourceLabel == "tcr")

        settings.hidePersonalInfo = false
        let model = store.menuCardModel(for: .claude, context: context, now: self.now)
        #expect(model.email == carol.displayLabel)
    }

    @Test
    func `claude-swap menu cards keep the claude-swap source`() throws {
        let accounts = try self.tcrAccounts(source: .claudeSwap)
        let context = ClaudeSwapAccountMenuDisplay.cardContext(
            for: accounts[0],
            planLabel: nil,
            adapterError: nil,
            switchError: nil)
        #expect(context.account?.sourceLabel == "claude-swap")
    }

    // MARK: Privacy labels

    @Test
    func `hide personal info gives tcr accounts their slot ordinal`() throws {
        let (settings, store) = self.makeStore()
        let accounts = try self.tcrAccounts()
        settings.hidePersonalInfo = true
        for account in accounts {
            let expected = "Account \(account.id.opaqueID)"
            #expect(ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account) != nil)
            #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true) == expected)
            #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: false) == account.displayLabel)
            let context = ClaudeSwapAccountMenuDisplay.cardContext(
                for: account,
                planLabel: nil,
                adapterError: nil,
                switchError: nil)
            let model = store.menuCardModel(for: .claude, context: context, now: self.now)
            #expect(model.email == expected)
            #expect(!model.email.contains("@"))
        }
    }

    @Test
    func `an unknown source with a numeric slot still gets no ordinal`() {
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "some-future-tool", opaqueID: "2"),
            provider: .claude,
            displayLabel: "private@example.com",
            isActive: false,
            snapshot: nil,
            error: nil,
            sourceLabel: "some-future-tool")
        #expect(ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account) == nil)
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true).isEmpty)
    }

    // MARK: Widget pin identity

    @Test
    func `the same slot and email under claude-swap and tcr get different widget pins`() async throws {
        let swapPins = try await self.widgetPins(source: "claude-swap")
        let tcrPins = try await self.widgetPins(source: "tcr")
        #expect(swapPins.count == 1)
        #expect(tcrPins.count == 1)
        #expect(swapPins != tcrPins)
        #expect(tcrPins.allSatisfy { !$0.hasPrefix("claude/swap:") })
    }

    @Test
    func `claude-swap widget pins keep the exact bytes main writes`() async throws {
        // main builds `claude/swap:<slot>:<sha256(slot NUL lowercased email)>`; saved pins depend on it.
        let digest = SHA256.hash(data: Data("1\u{0}account1@example.invalid".utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        let swapPins = try await self.widgetPins(source: "claude-swap")
        #expect(swapPins == ["claude/swap:1:\(fingerprint)"])

        // The provider entry's quota owner uses the same key, so it splits by source the same way.
        let swap = self.account(source: "claude-swap", slot: "1", active: true)
        let tcr = self.account(source: "tcr", slot: "1", active: true)
        #expect(UsageStore.claudeSwapWidgetOwnerKey(for: swap) == "claude/swap:1:\(fingerprint)")
        #expect(UsageStore.claudeSwapWidgetOwnerKey(for: tcr) == "claude/tcr:1:\(fingerprint)")
        let unknown = self.account(source: "some-future-tool", slot: "1", active: true)
        #expect(UsageStore.claudeSwapWidgetOwnerKey(for: unknown) == nil)
    }

    // MARK: Helpers

    private func tcrAccounts(source: ClaudeSwapAccountSource = .tcr) throws -> [ProviderAccountUsageSnapshot] {
        let url = try #require(Bundle.module.url(
            forResource: "tcr-list-v1",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Claude"))
        let list = try ClaudeSwapListParser.parse(Data(contentsOf: url))
        return ClaudeSwapAccountProjection.accountSnapshots(from: list, source: source, now: self.now)
    }

    private func widgetPins(source: String) async throws -> [String] {
        let (settings, store) = self.makeStore()
        settings.accountWidgetsEnabled = true
        store.claudeSwapAccountSnapshots = [self.account(source: source, slot: "1", active: true)]
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "tcr-consumer-pins")
        await store.widgetSnapshotPersistTask?.value
        let snapshot = try #require(saved)
        return snapshot.accounts.filter { $0.provider == .claude }.map(\.id)
    }

    @Test(arguments: [false, true])
    func `source changes reject late lists even before runtime cancellation`(whileLoadingHistory: Bool) async throws {
        let (settings, store) = self.makeStore()
        var releaseHistory = !whileLoadingHistory
        defer { releaseHistory = true }
        if whileLoadingHistory {
            store.planUtilizationHistoryLoaded = false
            store.planUtilizationHistoryLoadTask = Task { @MainActor in
                while !releaseHistory {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                store.planUtilizationHistoryLoaded = true
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tcr-late-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adapter")
        let entered = directory.appendingPathComponent("adapter.entered")
        let release = directory.appendingPathComponent("adapter.release")
        try #"""
        #!/bin/sh
        [ "$1" = "--list" ] && [ "$2" = "--json" ] || exit 64
        touch "$0.entered"
        while [ ! -f "$0.release" ]; do /bin/sleep 0.01; done
        echo '{"schemaVersion":1,"activeAccountNumber":null,"accounts":[
          {"number":1,"email":"fixture@example.invalid","organizationUuid":"fixture-org","active":false,
           "usageStatus":"ok","usage":{"fiveHour":{"pct":12.5,"resetsAt":"2099-01-01T00:00:00Z"}}}]}'
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.claudeSwapExecutablePath = executable.path
        store.claudeSwapTransientState.versionProbedPath = executable.path
        let refresh = Task { await store.refreshClaudeSwapAccounts() }
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: entered.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let didEnter = FileManager.default.fileExists(atPath: entered.path)
            if whileLoadingHistory {
                try Data().write(to: release)
                let publishDeadline = ContinuousClock.now + .seconds(5)
                while store.claudeSwapLastRefreshAt == nil, ContinuousClock.now < publishDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            settings.claudeSwapSource = .tcr
            releaseHistory = true
            try Data().write(to: release)
            await refresh.value
            #expect(didEnter)
            #expect(store.claudeSwapAccountSnapshots.isEmpty)
            #expect(store.claudeSwapLastRefreshAt == nil)
            #expect(store.claudeSwapLastError == nil)
            #expect(store.planUtilizationHistory[.claude]?.isEmpty != false)
        } catch {
            releaseHistory = true
            try? Data().write(to: release)
            await refresh.value
            throw error
        }
    }

    private func account(source: String, slot: String, active: Bool) -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: source, opaqueID: slot),
            provider: .claude,
            displayLabel: "Account \(slot)",
            accountEmail: "account\(slot)@example.invalid",
            isActive: active,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.now),
            error: nil,
            sourceLabel: source)
    }

    private func makeStore() -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(
            suiteName: "ClaudeSwapTcrConsumerTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.claude], settings: settings)
        settings.claudeSwapEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/synthetic", fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }
}
