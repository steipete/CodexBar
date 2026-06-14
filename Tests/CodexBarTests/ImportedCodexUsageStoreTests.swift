@testable import CodexBar
@testable import CodexBarCore
import Foundation
import Testing

@MainActor
struct ImportedCodexUsageStoreTests {
    @Test
    func `settings store persists imported credential source additions and removals`() throws {
        let suite = "ImportedCodexUsageStoreTests-settings-persist-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]))
        let settings = SettingsStore(configStore: configStore)
        let sourceID = UUID()

        settings.addImportedCredentialSource(ImportedCredentialSource(
            id: sourceID,
            platform: "codex",
            path: "/tmp/imported-codex",
            format: CLIProxyCodexAdapter.format,
            label: "Imported"))

        var loadedConfig = try configStore.load()
        var reloaded = try #require(loadedConfig)
        #expect(reloaded.importedCredentialSources.map(\.id) == [sourceID])
        #expect(settings.importedCodexCredentialSources.map(\.id) == [sourceID])

        settings.removeImportedCredentialSource(id: sourceID)

        loadedConfig = try configStore.load()
        reloaded = try #require(loadedConfig)
        #expect(reloaded.importedCredentialSources.isEmpty)
        #expect(settings.importedCodexCredentialSources.isEmpty)
    }

    @Test
    func `imported codex expired error maps to imported credential health label`() {
        let health = CodexAccountHealth.status(forError: "Imported Codex credential expired. Refresh it in the source tool.")

        #expect(health == .importedCredentialExpired)
        #expect(health.label == "Imported Codex credential expired. Refresh it in the source tool.")
    }

    @Test
    func `settings exposes only cliproxyapi codex imported credential sources`() throws {
        let suite = "ImportedCodexUsageStoreTests-source-filter-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(
            providers: [ProviderConfig(id: .codex, enabled: true)],
            importedCredentialSources: [
                ImportedCredentialSource(
                    platform: "codex",
                    path: "/tmp/codex",
                    format: CLIProxyCodexAdapter.format),
                ImportedCredentialSource(
                    platform: "claude",
                    path: "/tmp/claude",
                    format: CLIProxyCodexAdapter.format),
                ImportedCredentialSource(
                    platform: "codex",
                    path: "/tmp/other",
                    format: "other-format"),
            ]))
        let settings = SettingsStore(configStore: configStore)

        #expect(settings.importedCodexCredentialSources.map(\.path) == ["/tmp/codex"])
    }

    @Test
    func `refresh imported codex accounts live reads fixtures without modifying files`() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validFile = directory.appendingPathComponent("codex-valid.json")
        let disabledFile = directory.appendingPathComponent("codex-disabled.json")
        let expiredFile = directory.appendingPathComponent("codex-expired.json")
        try Self.writeCLIProxyCodexFile(
            to: validFile,
            email: "valid@example.com",
            accountID: "account-valid",
            expired: "2026-06-22T14:11:59+09:00")
        try Self.writeCLIProxyCodexFile(
            to: disabledFile,
            email: "disabled@example.com",
            accountID: "account-disabled",
            expired: "2026-06-22T14:11:59+09:00",
            disabled: true)
        try Self.writeCLIProxyCodexFile(
            to: expiredFile,
            email: "expired@example.com",
            accountID: "account-expired",
            expired: "2026-06-13T00:00:00Z")
        let before = try Self.contents(of: [validFile, disabledFile, expiredFile])

        let suite = "ImportedCodexUsageStoreTests-refresh-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(
            providers: [ProviderConfig(id: .codex, enabled: true)],
            importedCredentialSources: [
                ImportedCredentialSource(
                    platform: "codex",
                    path: directory.path,
                    format: CLIProxyCodexAdapter.format),
            ]))
        let settings = SettingsStore(configStore: configStore)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["CODEX_HOME": "/tmp/ambient-codex-home"])
        let usageUpdatedAt = try Self.date("2026-06-14T00:00:00Z")
        store._test_importedCodexUsageFetchOverride = { account in
            if account.isExpired {
                throw BorrowedCredentialError.expired(accountID: account.id)
            }
            return ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: usageUpdatedAt),
                credits: nil,
                dashboard: nil,
                sourceLabel: "borrowed",
                strategyID: "codex.borrowed",
                strategyKind: .oauth)
        }

        await store.refreshImportedCodexAccounts(now: try Self.date("2026-06-14T00:00:00Z"))

        let snapshots = store.importedCodexAccountSnapshots
        #expect(snapshots.count == 2)
        #expect(snapshots.map(\.account.email).sorted() == ["expired@example.com", "valid@example.com"])
        #expect(snapshots.first { $0.account.email == "valid@example.com" }?.snapshot?.primary?.usedPercent == 25)
        #expect(snapshots.first { $0.account.email == "valid@example.com" }?.sourceLabel == "borrowed")
        #expect(snapshots.first { $0.account.email == "expired@example.com" }?.snapshot == nil)
        #expect(snapshots.first { $0.account.email == "expired@example.com" }?.error?.contains("expired") == true)
        #expect(try Self.contents(of: [validFile, disabledFile, expiredFile]) == before)
    }

    @Test
    func `refresh imported codex accounts is cheap no-op without sources`() async throws {
        let suite = "ImportedCodexUsageStoreTests-empty-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)]))
        let settings = SettingsStore(configStore: configStore)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        await store.refreshImportedCodexAccounts()

        #expect(store.importedCodexAccountSnapshots.isEmpty)
    }

    @Test
    func `refresh imported codex accounts deduplicates loaded accounts by id`() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("codex-valid.json")
        try Self.writeCLIProxyCodexFile(
            to: file,
            email: "valid@example.com",
            accountID: "account-valid",
            expired: "2026-06-22T14:11:59+09:00")

        let suite = "ImportedCodexUsageStoreTests-dedup-\(UUID().uuidString)"
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(
            providers: [ProviderConfig(id: .codex, enabled: true)],
            importedCredentialSources: [
                ImportedCredentialSource(
                    platform: "codex",
                    path: directory.path,
                    format: CLIProxyCodexAdapter.format),
                ImportedCredentialSource(
                    platform: "codex",
                    path: directory.standardizedFileURL.path,
                    format: CLIProxyCodexAdapter.format),
            ]))
        let settings = SettingsStore(configStore: configStore)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._test_importedCodexUsageFetchOverride = { _ in
            ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                credits: nil,
                dashboard: nil,
                sourceLabel: "borrowed",
                strategyID: "codex.borrowed",
                strategyKind: .oauth)
        }

        await store.refreshImportedCodexAccounts(now: try Self.date("2026-06-14T00:00:00Z"))

        #expect(store.importedCodexAccountSnapshots.count == 1)
        #expect(store.importedCodexAccountSnapshots.first?.account.email == "valid@example.com")
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedCodexUsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeCLIProxyCodexFile(
        to url: URL,
        type: String = "codex",
        email: String,
        accountID: String,
        accessToken: String = "access-token",
        idToken: String = "id-token",
        refreshToken: String = "refresh-token",
        lastRefresh: String = "2026-06-10T14:11:59+09:00",
        expired: String,
        disabled: Bool = false) throws
    {
        let object: [String: Any] = [
            "type": type,
            "email": email,
            "account_id": accountID,
            "access_token": accessToken,
            "id_token": idToken,
            "refresh_token": refreshToken,
            "last_refresh": lastRefresh,
            "expired": expired,
            "disabled": disabled,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func contents(of urls: [URL]) throws -> [URL: Data] {
        try Dictionary(uniqueKeysWithValues: urls.map { ($0, try Data(contentsOf: $0)) })
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
