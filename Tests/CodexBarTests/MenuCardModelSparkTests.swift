import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct MenuCardModelSparkTests {
    @Test
    func showsSparkSessionAndWeeklyMetricsWhenCodexSparkUsagePresent() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(6000),
                resetDescription: nil),
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
                                resetsAt: now.addingTimeInterval(5400),
                                resetDescription: nil)),
                        UsageBucketSnapshot(
                            id: "codex.spark.weekly",
                            title: "Weekly",
                            window: RateWindow(
                                usedPercent: 17,
                                windowMinutes: 10080,
                                resetsAt: now.addingTimeInterval(7200),
                                resetDescription: nil)),
                    ]),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.count == 4)
        #expect(model.metrics.contains { $0.id == "codex.spark.session" && $0.title == "Session" && $0.percent == 97 })
        #expect(model.metrics.contains { $0.id == "codex.spark.weekly" && $0.title == "Weekly" && $0.percent == 83 })

        let groups = UsageMenuCardView.metricGroups(metrics: model.metrics)
        #expect(groups.count == 2)
        let sparkGroup = try #require(groups.last)
        #expect(sparkGroup.id == "codex.spark")
        #expect(sparkGroup.title == "GPT-5.3-Codex-Spark")
        #expect(sparkGroup.metrics.map(\.id) == ["codex.spark.session", "codex.spark.weekly"])
    }

    @Test
    func doesNotCreateSupplementalGroupWithoutUsageBucketGroups() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 300, resetsAt: now, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: now, resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(UsageMenuCardView.metricGroups(metrics: model.metrics).count == 1)
        #expect(model.metrics.contains { $0.groupID != nil } == false)
    }

    @Test
    func preservesProviderOwnedPrimaryBucketGroupAlongsideBuiltInPrimaryGroup() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 300, resetsAt: now, resetDescription: nil),
            secondary: nil,
            usageBucketGroups: [
                UsageBucketGroupSnapshot(
                    id: "primary",
                    title: "Provider Primary",
                    buckets: [
                        UsageBucketSnapshot(
                            id: "primary.session",
                            title: "Session",
                            window: RateWindow(
                                usedPercent: 3,
                                windowMinutes: 300,
                                resetsAt: now.addingTimeInterval(5400),
                                resetDescription: nil)),
                    ]),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let groups = UsageMenuCardView.metricGroups(metrics: model.metrics)
        #expect(groups.count == 2)
        #expect(groups.map(\.kind) == [.builtInPrimary, .providerBucket])
        #expect(groups.contains { $0.id == "primary" && $0.kind == .providerBucket })
        #expect(UsageMenuCardView.primaryMetricGroup(metrics: model.metrics)?.kind == .builtInPrimary)
        #expect(UsageMenuCardView.supplementalMetricGroups(metrics: model.metrics).map(\.id) == ["primary"])
    }

    @Test
    func keepsInternalViewIdentityUniqueWhenProviderGroupMatchesBuiltInSentinel() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 300, resetsAt: now, resetDescription: nil),
            secondary: nil,
            usageBucketGroups: [
                UsageBucketGroupSnapshot(
                    id: "__builtInPrimary",
                    title: "Provider Sentinel",
                    buckets: [
                        UsageBucketSnapshot(
                            id: "__builtInPrimary.session",
                            title: "Session",
                            window: RateWindow(
                                usedPercent: 3,
                                windowMinutes: 300,
                                resetsAt: now.addingTimeInterval(5400),
                                resetDescription: nil)),
                    ]),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let groups = UsageMenuCardView.metricGroups(metrics: model.metrics)
        #expect(groups.map(\.internalID) == ["builtInPrimary", "providerBucket:__builtInPrimary"])
    }
}
