import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSwapRichUsageFixture {
    static let now = Date(timeIntervalSince1970: 1_787_011_200)
    let store: UsageStore
    let accounts: [ProviderAccountUsageSnapshot]
    let arguments: String

    static func withFixture(
        activeNeedsRepair: Bool = false,
        _ body: @MainActor (Self) async throws -> Void) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-rich-proof-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await CodexCredentialFileAccess.withFixtureScope(.init()) {
            try await OpenAIDashboardCacheStore.$cacheURLOverride
                .withValue(root.appendingPathComponent("dashboard.json")) {
                    try await CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                        try await body(Self.make(root: root, activeNeedsRepair: activeNeedsRepair))
                    }
                }
        }
    }

    func model(
        for slot: String,
        hidePersonalInfo: Bool = false,
        now: Date = Self.now,
        adapterError: String? = nil,
        switchError: String? = nil) throws -> UsageMenuCardView.Model
    {
        let account = try #require(self.accounts.first { $0.id.opaqueID == slot })
        self.store.settings.hidePersonalInfo = hidePersonalInfo
        let context = ClaudeSwapAccountMenuDisplay.cardContext(
            for: account,
            planLabel: ClaudeSwapAccountMenuDisplay.actionLabel(
                for: account,
                switchingAccountID: self.store.claudeSwapTransientState.switchingAccountID,
                switchInFlight: self.store.claudeSwapTransientState.task != nil),
            adapterError: adapterError,
            switchError: switchError)
        return self.store.menuCardModel(for: .claude, context: context, now: now)
    }

    private static func make(root: URL, activeNeedsRepair: Bool) async throws -> Self {
        let executable = root.appendingPathComponent("cswap")
        let script = #"""
        #!/bin/sh
        if [ "$#" -ne 2 ] || [ "$1" != "--list" ] || [ "$2" != "--json" ]; then
          exit 64
        fi
        printf '%s\n' "$@" > "$0.args"
        exec /bin/cat "$0.json"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Self.payload(activeNeedsRepair: activeNeedsRepair).write(to: executable.appendingPathExtension("json"))
        let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: executable.path)
        let arguments = try String(contentsOf: executable.appendingPathExtension("args"), encoding: .utf8)
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: Self.now)

        let settings = testSettingsStore(
            suiteName: "ClaudeSwapRichUsageFixture",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            prepareDefaults: { defaults in
                defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                defaults.set(true, forKey: "debugDisableKeychainAccess")
            })
        settings.usageBarsShowUsed = true
        settings.paceVisible = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.hidePersonalInfo = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(
                homeDirectory: root.path,
                fileExists: { _ in false },
                directoryContents: { _ in nil }),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root
                .appendingPathComponent("history.json")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: root
                .appendingPathComponent("plan-history")),
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        store.claudeSwapAccountSnapshots = accounts
        return Self(store: store, accounts: accounts, arguments: arguments)
    }

    private static func payload(activeNeedsRepair: Bool) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let sessionReset = formatter.string(from: Self.now.addingTimeInterval(3600))
        let weeklyReset = formatter.string(from: Self.now.addingTimeInterval(86400))
        let captured = formatter.string(from: Self.now.addingTimeInterval(-3600))
        func measurement(_ session: Double, _ weekly: Double) -> [String: Any] {
            [
                "fiveHour": ["pct": session, "resetsAt": sessionReset],
                "sevenDay": ["pct": weekly, "resetsAt": weeklyReset],
            ]
        }
        func account(_ slot: Int, _ alias: String, _ status: String) -> [String: Any] {
            [
                "number": slot, "email": "slot\(slot)@example.invalid", "organizationName": "",
                "alias": alias, "active": slot == 1, "usageStatus": status, "usage": NSNull(),
            ]
        }
        var active = account(1, "Primary", activeNeedsRepair ? "foreign_credential" : "ok")
        var live = measurement(26, 42)
        live["spend"] = ["used": 5.25, "limit": 20, "pct": 26.25, "currency": "USD"]
        if activeNeedsRepair {
            active["lastGoodUsage"] = live
            active["lastGoodFetchedAt"] = captured
        } else {
            active["usage"] = live
            active["usageFetchedAt"] = formatter.string(from: Self.now)
        }
        var expired = account(2, "Research", "token_expired")
        expired["lastGoodUsage"] = measurement(62, 41)
        expired["lastGoodFetchedAt"] = captured
        var unavailable = account(3, "Personal", "unavailable")
        unavailable["lastGoodUsage"] = measurement(12, 30)
        unavailable["lastGoodFetchedAt"] = captured
        var foreign = account(4, "Travel", "foreign_credential")
        foreign["disabled"] = true
        foreign["lastGoodUsage"] = measurement(40, 55)
        foreign["lastGoodFetchedAt"] = captured
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "activeAccountNumber": 1,
            "accounts": [active, expired, unavailable, foreign],
        ], options: [.sortedKeys])
    }
}
