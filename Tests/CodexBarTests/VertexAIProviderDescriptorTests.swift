import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct VertexAIProviderDescriptorTests {
    @Test
    func `descriptor metadata and tokenCost configuration match M2 parity contract`() {
        let descriptor = VertexAIProviderDescriptor.descriptor
        #expect(descriptor.id == .vertexai)
        #expect(descriptor.metadata.widgetSelectable)
        #expect(descriptor.tokenCost.settingsStatusOrder == 4)
        #expect(descriptor.tokenCost.showsHintInProviderDetails)
        #expect(descriptor.tokenCost.menuHintLines == [.localized("cost_estimate_hint")])
        #expect(descriptor.tokenCost.chartEstimateDisclaimer == .localized("vertexai_cost_estimate_hint"))
        #expect(descriptor.presentation.menuCard.supportsInlineTokenCostDashboard)
        #expect(descriptor.presentation.menuCard.primaryDescriptionPlacement == .detail)
        #expect(descriptor.presentation.menuCard.hidesPrimaryResetWithoutDate)
        #expect(descriptor.presentation.menuCard.showsSecondaryBalanceDescription)
    }

    @Test
    func `mapUsage honors primaryBarMetric builds provider-siloed details and keeps continuous quotas reset-free`()
        throws
    {
        let credentials = VertexAIOAuthCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            clientId: "client",
            clientSecret: "secret",
            projectId: "my-vertex-project",
            email: "dev@example.com",
            expiryDate: Date().addingTimeInterval(3600))

        let rateBucket = VertexAIQuotaBucketUsage(
            quotaMetric: "aiplatform.googleapis.com/generate_content_requests_per_minute",
            limitName: "PerMinute",
            displayName: "Generate requests",
            location: "us-central1",
            baseModel: "gemini-2.5-pro",
            cadence: .perMinute,
            usage: 45,
            limit: 100,
            usedPercent: 45,
            exceededCount: 2,
            unit: "1/min/{project}",
            resetsAt: nil)
        let allocBucket = VertexAIQuotaBucketUsage(
            quotaMetric: "aiplatform.googleapis.com/concurrent_requests",
            limitName: "Concurrent",
            displayName: "Concurrent requests",
            location: "global",
            baseModel: nil,
            cadence: .allocation,
            usage: 80,
            limit: 100,
            usedPercent: 80,
            exceededCount: 0,
            unit: nil,
            resetsAt: nil)
        let serving = VertexAIOnlineServingSummary(
            totalInvocations: 25,
            inputTokens: 12000,
            outputTokens: 3000,
            sharedInvocations: 20,
            dedicatedInvocations: 5,
            sharedTokens: 13000,
            dedicatedTokens: 2000,
            models: [
                VertexAIOnlineServingModelSummary(
                    modelUserID: "gemini-2.5-pro",
                    location: "us-central1",
                    publisher: "google",
                    requestType: "shared",
                    invocations: 20,
                    inputTokens: 10000,
                    outputTokens: 3000),
            ])
        let response = VertexAIUsageResponse(
            requestsUsedPercent: 80,
            tokensUsedPercent: nil,
            resetsAt: nil,
            resetDescription: nil,
            rawData: nil,
            rateQuotas: [rateBucket],
            allocationQuotas: [allocBucket],
            highestRateQuota: rateBucket,
            highestAllocationQuota: allocBucket,
            totalExceededCount: 2,
            onlineServingSummary: serving)

        // Auto picks highest % (80% allocation) first, 45% rate second
        let autoSnap = VertexAIOAuthFetchStrategy.mapUsage(
            response,
            credentials: credentials,
            settings: VertexAIProviderSettings(regionFilter: "us-central1", primaryBarMetric: .auto))
        #expect(autoSnap.primary?.usedPercent == 80)
        #expect(autoSnap.primary?.title == "Allocation quota")
        #expect(autoSnap.secondary?.usedPercent == 45)
        #expect(autoSnap.secondary?.title == "Rate quota (RPM)")
        #expect(autoSnap.identity?.providerID == .vertexai)
        #expect(autoSnap.identity?.accountOrganization == "my-vertex-project")
        #expect(autoSnap.identity?.loginMethod == "gcloud")

        // Rate quota preference forces rate primary
        let rateSnap = VertexAIOAuthFetchStrategy.mapUsage(
            response,
            credentials: credentials,
            settings: VertexAIProviderSettings(primaryBarMetric: .rateQuota))
        #expect(rateSnap.primary?.usedPercent == 45)
        #expect(rateSnap.primary?.title == "Rate quota (RPM)")
        #expect(rateSnap.primary?.windowMinutes == 1)
        #expect(rateSnap.primary?.resetsAt == nil)
        #expect(rateSnap.secondary?.usedPercent == 80)

        let labels = VertexAIProviderDescriptor.descriptor.presentation.rateWindowLabels(
            metadata: VertexAIProviderDescriptor.descriptor.metadata,
            snapshot: rateSnap)
        #expect(labels.primary == "Rate quota (RPM)")
        #expect(labels.secondary == "Allocation quota")

        // MenuCardView must not prefix continuous quotas with "Resets "
        let cardModel = UsageMenuCardView.Model.make(.init(
            provider: .vertexai,
            metadata: VertexAIProviderDescriptor.descriptor.metadata,
            snapshot: rateSnap,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date()))
        #expect(cardModel.metrics.first?.resetText == nil)
        #expect(cardModel.metrics.first?.detailText?.contains("peak/min") == true)
        #expect(cardModel.metrics.dropFirst().first?.resetText == nil)
        #expect(cardModel.metrics.dropFirst().first?.detailText?.contains("allocated") == true)

        #expect(autoSnap.details.map(\.title) == ["Quota breakdown", "Online serving (24h)", "Active filter"])
        let quotaSection = try #require(autoSnap.details.first)
        #expect(quotaSection.rows.first?.severity == .warning)
        #expect(quotaSection.rows.last?.severity == .critical)
    }

    @Test
    func `projectIDOverride precedes CODEXBAR_VERTEX_PROJECT_ID config_default and env`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertex-creds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configsDir = dir.appendingPathComponent("configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
        let configFile = configsDir.appendingPathComponent("config_default")
        try """
        [other]
        project = wrong-section-project

        [core]
        project = core-config-project
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let baseEnv = [
            "CLOUDSDK_CONFIG": dir.path,
            "GOOGLE_CLOUD_PROJECT": "env-gcp-project",
        ]
        #expect(VertexAIOAuthCredentialsStore.loadProjectId(environment: baseEnv) == "core-config-project")

        var withCodexBarEnv = baseEnv
        withCodexBarEnv["CODEXBAR_VERTEX_PROJECT_ID"] = "codexbar-env-project"
        #expect(VertexAIOAuthCredentialsStore.loadProjectId(environment: withCodexBarEnv) == "codexbar-env-project")
        #expect(VertexAIOAuthCredentialsStore.loadProjectId(
            environment: withCodexBarEnv,
            projectIDOverride: "explicit-override-project") == "explicit-override-project")
    }

    @Test
    func `localClaudeLogsOnly short-circuits Cloud Monitoring HTTP calls`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertex-local-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let adcURL = dir.appendingPathComponent("application_default_credentials.json")
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-access",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(to: adcURL, atomically: true, encoding: .utf8)

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            Issue.record("Unexpected HTTP call for localClaudeLogsOnly: \(url.absoluteString)")
            throw URLError(.badURL)
        }
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: [
                "CLOUDSDK_CONFIG": dir.path,
                "GOOGLE_CLOUD_PROJECT": "local-only-proj",
            ],
            settings: ProviderSettingsSnapshot.make(
                vertexai: VertexAIProviderSettings(telemetryCostSource: .localClaudeLogsOnly)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))

        let result = try await VertexAIOAuthFetchStrategy.$transportForTesting.withValue(transport) {
            try await VertexAIOAuthFetchStrategy().fetch(context)
        }
        #expect(await transport.requests().isEmpty)
        #expect(result.usage.primary == nil)
        #expect(result.usage.identity?.accountOrganization == "local-only-proj")
    }
}
