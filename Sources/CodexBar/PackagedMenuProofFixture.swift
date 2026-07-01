import CodexBarCore
import Foundation

/// Debug-only deterministic data seam for validating the packaged production menu without account access.
@MainActor
enum PackagedMenuProofFixture {
    static let environmentKey = "CODEXBAR_PACKAGED_MENU_FIXTURE"
    private static let fixtureName = "codex-dashboard-cost"
    private static let defaultsSuite = "com.steipete.codexbar.packaged-menu-proof"

    struct Runtime {
        let settings: SettingsStore
        let store: UsageStore
        let account: AccountInfo
    }

    static func isRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        environment[self.environmentKey] == self.fixtureName
        #else
        false
        #endif
    }

    static func makeRuntimeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Runtime?
    {
        #if DEBUG
        guard self.isRequested(environment: environment) else { return nil }

        guard let defaults = UserDefaults(suiteName: self.defaultsSuite) else { return nil }
        defaults.removePersistentDomain(forName: self.defaultsSuite)
        defaults.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
        defaults.set(true, forKey: "debugDisableKeychainAccess")
        defaults.set(false, forKey: "launchAtLogin")

        let root = URL(
            fileURLWithPath: environment["CODEXBAR_PACKAGED_MENU_FIXTURE_ROOT"] ?? NSTemporaryDirectory(),
            isDirectory: true)
        let configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("codexbar-proof-config.json"))
        let providers = UsageProvider.allCases.map { provider in
            ProviderConfig(id: provider, enabled: provider == .codex)
        }
        do {
            try configStore.save(CodexBarConfig(providers: providers))
        } catch {
            return nil
        }

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            performInitialProviderDetection: false,
            performStartupSideEffects: false)
        settings._test_codexAccountSnapshotLoader = { activeSource in
            CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: activeSource,
                hasUnreadableAddedAccountStore: false)
        }
        StatusItemController.setCodexAccountMenuProjectionRevalidationEnabledForTesting(false)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.mergeIcons = false
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 365
        settings.costSummaryDisplayStyle = .both
        settings.showOptionalCreditsAndExtraUsage = false
        settings.hidePersonalInfo = true

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 24,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "fixture@example.invalid",
                    accountOrganization: nil,
                    loginMethod: "Fixture Plan")),
            provider: .codex)
        store._setTokenSnapshotForTesting(self.makeCostSnapshot(now: now), provider: .codex)

        return Runtime(
            settings: settings,
            store: store,
            account: AccountInfo(email: nil, plan: nil))
        #else
        _ = environment
        return nil
        #endif
    }

    #if DEBUG
    private static func makeCostSnapshot(now: Date) -> CostUsageTokenSnapshot? {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let breakdown = (-35...1).compactMap { offset -> OpenAIDashboardDailyBreakdown? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let credits: Double = switch offset {
            case -35: 25000 // Outside the dashboard's 30-day display contract.
            case 0: 250 // Local Today: $10.
            case 1: 2500 // Future/latest fixture point: must not become Today.
            default: 25
            }
            return OpenAIDashboardDailyBreakdown(
                day: formatter.string(from: date),
                services: [OpenAIDashboardServiceUsage(service: "Exec", creditsUsed: credits)],
                totalCreditsUsed: credits)
        }
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "fixture@example.invalid",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: breakdown,
            creditsPurchaseURL: nil,
            updatedAt: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        return dashboard.toCostUsageTokenSnapshot(
            historyDays: 365,
            now: now,
            calendar: calendar)
    }
    #endif
}
