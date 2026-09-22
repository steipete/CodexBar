import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct AntigravitySettingsPresentationTests {
    @Test(arguments: ["cli", "oauth", "offline", "app", "ide"], [nil, "running"] as [String?])
    func `settings identify the successful usage source independently of process detection`(
        source: String,
        detectedVersion: String?) throws
    {
        try Self.withFixture { settings, store in
            store.lastSourceLabels[.antigravity] = source
            store.versions[.antigravity] = detectedVersion
            let pane = ProvidersPane(provider: .antigravity, settings: settings, store: store)

            #expect(pane.providerSubtitle(.antigravity).hasPrefix("\(source)\n"))
            #expect(ProviderDetailView<EmptyView>.versionText(provider: .antigravity, store: store) == nil)
            #expect(store.version(for: .antigravity) == detectedVersion)
        }
    }

    @Test(arguments: AntigravityUsageDataSource.allCases)
    func `settings use the selected source before any successful fetch`(source: AntigravityUsageDataSource) throws {
        try Self.withFixture { settings, store in
            settings.antigravityUsageDataSource = source
            let pane = ProvidersPane(provider: .antigravity, settings: settings, store: store)

            #expect(pane.providerSubtitle(.antigravity) == "\(source.rawValue)\n\(L("usage_not_fetched_yet"))")
            #expect(ProviderDetailView<EmptyView>.versionText(provider: .antigravity, store: store) == nil)
        }
    }

    @Test
    func `settings retain source and failure state after an unsuccessful refresh`() throws {
        try Self.withFixture { settings, store in
            store.lastSourceLabels[.antigravity] = "oauth"
            store.errors[.antigravity] = "Synthetic quota refresh failed."
            let pane = ProvidersPane(provider: .antigravity, settings: settings, store: store)

            #expect(pane.providerSubtitle(.antigravity) == "oauth\n\(L("last_fetch_failed"))")
            #expect(pane.providerErrorDisplay(.antigravity)?.full == "Synthetic quota refresh failed.")
            #expect(ProviderDetailView<EmptyView>.versionText(provider: .antigravity, store: store) == nil)
        }
    }

    @Test
    func `offline diagnostics remain visible without marking the successful fallback stale`() throws {
        try Self.withFixture { settings, store in
            store.lastSourceLabels[.antigravity] = "offline"
            store.snapshots[.antigravity] = Self.snapshot()
            store.diagnostics[.antigravity] = "Live Antigravity usage is unavailable; showing offline data."
            let pane = ProvidersPane(provider: .antigravity, settings: settings, store: store)

            #expect(pane.providerSubtitle(.antigravity).hasPrefix("offline\n"))
            #expect(!store.isStale(provider: .antigravity))
            #expect(!pane.providerSubtitle(.antigravity).contains(L("last_fetch_failed")))
            #expect(pane.providerErrorDisplay(.antigravity)?.full == store.diagnostic(for: .antigravity))
        }
    }

    @Test(arguments: [nil, "1.2.3"] as [String?])
    func `providers with version detection retain the shared version row`(detectedVersion: String?) throws {
        try Self.withFixture { _, store in
            store.versions[.codex] = detectedVersion
            #expect(ProviderDetailView<EmptyView>.versionText(provider: .codex, store: store) ==
                (detectedVersion ?? L("not detected")))
        }
    }

    @Test
    func `render synthetic settings comparison when requested`() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_ANTIGRAVITY_SETTINGS_PROOF_DIR"] else { return }
        try #require(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        try #require(environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1")
        try #require(environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1")
        try #require(environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.withFixture { settings, store in
            store.lastSourceLabels[.antigravity] = "offline"
            store.snapshots[.antigravity] = Self.snapshot()
            let metadata = store.metadata(for: .antigravity)
            let context = ProviderPresentationContext(
                provider: .antigravity, settings: settings, store: store, metadata: metadata)
            let pane = ProvidersPane(provider: .antigravity, settings: settings, store: store)
            let afterSubtitle = pane.providerSubtitle(.antigravity)
            let usageText = afterSubtitle.split(separator: "\n").dropFirst().joined(separator: "\n")
            let beforeSubtitle = "\(ProviderPresentation.standardDetailLine(context: context))\n\(usageText)"
            let model = Self.model(metadata: metadata, snapshot: store.snapshots[.antigravity])

            try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                for before in [true, false] {
                    let phase = before ? "before" : "after"
                    let title = before ? "Before · reconstructed synthetic baseline" : "After · synthetic settings"
                    let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 18) {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                        ProviderDetailHeaderRow(
                            provider: .antigravity,
                            store: store,
                            isEnabled: .constant(true),
                            subtitle: before ? beforeSubtitle : afterSubtitle,
                            onRefresh: {})
                        Divider()
                        ProviderDetailInfoRows(
                            provider: .antigravity,
                            store: store,
                            isEnabled: true,
                            versionText: before ? L("not detected") :
                                ProviderDetailView<EmptyView>.versionText(provider: .antigravity, store: store),
                            model: model)
                    }
                    .padding(24)
                    .frame(width: 640, height: 280, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light))
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage)
                    let data = try #require(NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("antigravity-settings-\(phase).png"))
                }
            }
        }
    }

    private static func snapshot() -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
    }

    private static func model(metadata: ProviderMetadata, snapshot: UsageSnapshot?) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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
            hidePersonalInfo: true,
            now: Date()))
    }

    private static func withFixture(_ operation: (SettingsStore, UsageStore) throws -> Void) throws {
        try #require(SettingsStore.isRunningTests)
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(
            suiteName: "AntigravitySettingsPresentationTests",
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        defer {
            settings.configPersistTask?.cancel()
            settings.configFileWatcher?.stop()
        }
        settings.providerDetectionCompleted = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        try operation(settings, store)
        #expect(defaults.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
        #expect(SettingsStore.sharedDefaults == nil)
    }
}
