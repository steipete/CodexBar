import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexWorkspacesNavigationFixture {
    let files: CostUsageTestEnvironment
    let settings: SettingsStore
    let store: UsageStore

    init() throws {
        self.files = try CostUsageTestEnvironment()
        self.settings = testSettingsStore(
            suiteName: "CodexWorkspacesNavigationTests",
            config: CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: $0 == .codex)
            }),
            prepareDefaults: {
                // Isolation must precede SettingsStore's synchronous legacy migration.
                $0.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                $0.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
                $0.set(true, forKey: "debugDisableKeychainAccess")
                $0.set(true, forKey: "providerDetectionCompleted")
                $0.set(false, forKey: "openAIWebAccessEnabled")
            })
        self.settings.statusChecksEnabled = false
        self.settings.openAIWebAccessEnabled = false
        self.settings.costUsageEnabled = false
        self.settings.refreshFrequency = .manual
        let environment = [
            "HOME": self.files.root.path,
            "CODEX_HOME": self.files.codexHomeRoot.path,
            "XDG_CONFIG_HOME": self.files.root.appendingPathComponent(".config").path,
        ]
        self.settings._test_codexReconciliationEnvironment = environment
        self.store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: self.files.root.path, cacheTTL: 0),
            settings: self.settings,
            startupBehavior: .testing,
            environmentBase: environment)
        self.store._test_providerRefreshOverride = { _ in Issue.record("Unexpected provider transport") }
        self.store._test_widgetSnapshotSaveOverride = { _ in }
    }

    func makeController() -> StatusItemController {
        StatusItemController(
            store: self.store,
            settings: self.settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    func cleanup() {
        self.store.stopSharedSpendDashboardPublication()
        self.files.cleanup()
    }
}
