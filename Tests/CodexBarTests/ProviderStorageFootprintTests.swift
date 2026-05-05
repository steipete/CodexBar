import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderStorageFootprintTests {
    @Test
    func `scanner sums nested regular files and skips symlink targets`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("a.jsonl"))
        try Data(repeating: 2, count: 7).write(to: nested.appendingPathComponent("b.jsonl"))

        let external = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: external) }
        let target = external.appendingPathComponent("outside.bin")
        try Data(repeating: 3, count: 100).write(to: target)
        let link = root.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let footprint = ProviderStorageScanner().scan(provider: .codex, candidatePaths: [root.path])

        #expect(footprint.totalBytes == 12)
        #expect(footprint.paths == [root.path])
        #expect(footprint.missingPaths.isEmpty)
        #expect(footprint.components.map(\.name) == ["nested", "a.jsonl"])
        #expect(footprint.components.map(\.totalBytes) == [7, 5])
    }

    @Test
    func `scanner records missing paths without failing`() throws {
        let root = try Self.makeTemporaryDirectory()
        let missing = root.appendingPathComponent("missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let footprint = ProviderStorageScanner().scan(provider: .claude, candidatePaths: [missing.path])

        #expect(footprint.totalBytes == 0)
        #expect(footprint.paths.isEmpty)
        #expect(footprint.missingPaths == [missing.path])
    }

    @Test
    func `codex path catalog uses CODEX_HOME and managed homes`() {
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            managedHomePath: "/tmp/codex-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: nil)

        let paths = ProviderStoragePathCatalog.candidatePaths(
            for: .codex,
            environment: ["CODEX_HOME": "/tmp/codex-home"],
            managedCodexAccounts: [managed])

        #expect(paths == ["/tmp/codex-home", "/tmp/codex-managed-home"])
    }

    @Test
    func `codex path catalog falls back to default home`() {
        let paths = ProviderStoragePathCatalog.candidatePaths(for: .codex, environment: [:])
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .path

        #expect(paths.first == expected)
    }

    @Test
    func `claude recommendations use documented cleanup categories`() {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 28,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 10),
                .init(path: "\(root)/file-history", totalBytes: 8),
                .init(path: "\(root)/paste-cache", totalBytes: 6),
                .init(path: "\(root)/settings.json", totalBytes: 4),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let recommendations = footprint.cleanupRecommendations

        #expect(recommendations.map(\.path) == [
            "\(root)/projects",
            "\(root)/file-history",
            "\(root)/paste-cache",
        ])
        #expect(recommendations[0].consequence.contains("resume"))
        #expect(recommendations.allSatisfy { $0.riskLevel == .manualCleanup })
    }

    @Test
    func `codex recommendations stay under known homes and exclude auth and config`() {
        let root = "/Users/test/.codex"
        let footprint = ProviderStorageFootprint(
            provider: .codex,
            totalBytes: 51,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/sessions", totalBytes: 20),
                .init(path: "\(root)/archived_sessions", totalBytes: 15),
                .init(path: "\(root)/log", totalBytes: 12),
                .init(path: "\(root)/logs_2.sqlite", totalBytes: 11),
                .init(path: "\(root)/cache", totalBytes: 10),
                .init(path: "\(root)/shell_snapshots", totalBytes: 9),
                .init(path: "\(root)/auth.json", totalBytes: 4),
                .init(path: "\(root)/config.toml", totalBytes: 2),
                .init(path: "/tmp/outside/sessions", totalBytes: 99),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let recommendations = footprint.cleanupRecommendations

        #expect(recommendations.map(\.path) == [
            "\(root)/sessions",
            "\(root)/archived_sessions",
            "\(root)/cache",
            "\(root)/log",
            "\(root)/logs_2.sqlite",
            "\(root)/shell_snapshots",
        ])
        #expect(recommendations.map(\.bytes) == [20, 15, 10, 12, 11, 9])
    }

    @Test
    func `unknown provider storage returns no cleanup recommendations`() {
        let footprint = ProviderStorageFootprint(
            provider: .gemini,
            totalBytes: 10,
            paths: ["/Users/test/.gemini"],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "/Users/test/.gemini/cache", totalBytes: 10),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(footprint.cleanupRecommendations.isEmpty)
    }

    @Test
    @MainActor
    func `overview row carries storage text outside provider detail model`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: nil)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let overview = OverviewMenuCardRowView(model: model, storageText: "1.5 GB", width: 310)
        let detail = UsageMenuCardView(model: model, width: 310)

        #expect(overview.storageText == "1.5 GB")
        #expect(detail.model.provider == UsageProvider.claude)
    }

    @Test
    @MainActor
    func `storage detail view exposes cleanup recommendations while overview remains number only`() throws {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 10,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 10),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let detailView = StorageBreakdownMenuView(footprint: footprint, width: 310)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date(timeIntervalSince1970: 0)))
        let overview = OverviewMenuCardRowView(model: model, storageText: "10 B", width: 310)

        #expect(detailView.cleanupRecommendations.map(\.path) == ["\(root)/projects"])
        #expect(overview.storageText == "10 B")
    }

    @Test
    @MainActor
    func `storage detail view exposes copyable exact paths`() {
        let root = "/Users/test/.claude"
        let footprint = ProviderStorageFootprint(
            provider: .claude,
            totalBytes: 110,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [
                .init(path: "\(root)/projects", totalBytes: 100),
                .init(path: "\(root)/file-history", totalBytes: 10),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let detailView = StorageBreakdownMenuView(footprint: footprint, width: 310)

        #expect(detailView.copyablePaths.contains("\(root)/projects"))
        #expect(detailView.copyablePaths.contains("\(root)/file-history"))
    }

    @Test
    @MainActor
    func `storage path copy button writes exact path to pasteboard`() {
        let path = "/Users/test/.claude/projects/example"
        StoragePathCopyButton.copyToPasteboard(path)

        #expect(NSPasteboard.general.string(forType: .string) == path)
    }

    @Test
    @MainActor
    func `manual storage refresh updates deleted provider data`() async throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: sessions.appendingPathComponent("session.jsonl"))

        let suite = "ProviderStorageFootprintTests-storage-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        if let codexMetadata = ProviderDefaults.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["CODEX_HOME": codexHome.path])
        settings.providerStorageFootprintsEnabled = true
        store.managedCodexAccountsForStorageOverride = []

        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .codex)?.totalBytes == 32)

        try FileManager.default.removeItem(at: sessions)
        await store.refreshStorageFootprintsForOverviewNow()

        #expect(store.storageFootprint(for: .codex)?.totalBytes == 0)
        #expect(store.storageFootprintText(for: .codex) == "No local data found")
    }

    @Test
    @MainActor
    func `storage refresh is opt in and clears stale footprints when disabled`() async throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: codexHome.appendingPathComponent("session.jsonl"))

        let suite = "ProviderStorageFootprintTests-storage-opt-in-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        if let codexMetadata = ProviderDefaults.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: ["CODEX_HOME": codexHome.path])
        store.managedCodexAccountsForStorageOverride = []

        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .codex) == nil)

        settings.providerStorageFootprintsEnabled = true
        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .codex)?.totalBytes == 16)

        settings.providerStorageFootprintsEnabled = false
        await store.refreshStorageFootprintsForOverviewNow()
        #expect(store.storageFootprint(for: .codex) == nil)
        #expect(store.providerStorageFootprints.isEmpty)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderStorageFootprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
