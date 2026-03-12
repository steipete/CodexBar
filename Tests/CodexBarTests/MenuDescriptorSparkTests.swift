import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct MenuDescriptorSparkTests {
    @Test
    func codexUsageSectionSeparatesSparkRowsWhenLiveSparkUsageExists() throws {
        let suite = "MenuDescriptorSparkTests-live-spark"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: now, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: now, resetDescription: nil),
            usageBucketGroups: [
                UsageBucketGroupSnapshot(
                    id: "codex.spark",
                    title: "GPT-5.3-Codex-Spark",
                    buckets: [
                        UsageBucketSnapshot(
                            id: "codex.spark.session",
                            title: "Session",
                            window: RateWindow(
                                usedPercent: 3,
                                windowMinutes: 300,
                                resetsAt: now,
                                resetDescription: nil)),
                        UsageBucketSnapshot(
                            id: "codex.spark.weekly",
                            title: "Weekly",
                            window: RateWindow(
                                usedPercent: 17,
                                windowMinutes: 10080,
                                resetsAt: now,
                                resetDescription: nil)),
                    ]),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: nil)), provider: .codex)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains("GPT-5.3-Codex-Spark"))
        #expect(textLines.contains("Session: 97% left"))
        #expect(textLines.contains("Weekly: 83% left"))
    }

    @Test
    func codexSparkOnlyUsageSectionDoesNotInsertLeadingDivider() throws {
        let suite = "MenuDescriptorSparkTests-spark-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(UsageSnapshot(
            primary: nil,
            secondary: nil,
            usageBucketGroups: [
                UsageBucketGroupSnapshot(
                    id: "codex.spark",
                    title: "GPT-5.3-Codex-Spark",
                    buckets: [
                        UsageBucketSnapshot(
                            id: "codex.spark.session",
                            title: "Session",
                            window: RateWindow(
                                usedPercent: 3,
                                windowMinutes: 300,
                                resetsAt: now,
                                resetDescription: nil)),
                    ]),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: nil)), provider: .codex)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let entries = try #require(descriptor.sections.first?.entries)
        #expect(entries.count >= 3)
        #expect({
            guard case .text("Codex", .headline) = entries[0] else { return false }
            return true
        }())
        #expect({
            guard case .text("GPT-5.3-Codex-Spark", .headline) = entries[1] else { return false }
            return true
        }())
    }
}
