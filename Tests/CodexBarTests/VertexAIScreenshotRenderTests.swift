import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class VertexAIScreenshotRenderTests: XCTestCase {
    func test_renderParityMenuCard() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_VERTEX_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_VERTEX_SCREENSHOT_DIR to render synthetic Vertex AI parity card.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let credentials = VertexAIOAuthCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            clientId: "client",
            clientSecret: "secret",
            projectId: "apresai",
            email: "dev@example.com",
            expiryDate: now.addingTimeInterval(3600))

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
            exceededCount: 0,
            unit: "1/min/{project}",
            resetsAt: nil)
        let allocBucket = VertexAIQuotaBucketUsage(
            quotaMetric: "aiplatform.googleapis.com/concurrent_requests",
            limitName: "Concurrent",
            displayName: "Concurrent requests",
            location: "global",
            baseModel: nil,
            cadence: .allocation,
            usage: 24,
            limit: 100,
            usedPercent: 24,
            exceededCount: 0,
            unit: nil,
            resetsAt: nil)
        let serving = VertexAIOnlineServingSummary(
            totalInvocations: 42,
            inputTokens: 150_000,
            outputTokens: 50000,
            sharedInvocations: 42,
            dedicatedInvocations: 0,
            sharedTokens: 200_000,
            dedicatedTokens: 0,
            estimatedCostUSD: 1.48,
            hasUnpricedTokens: false,
            tokensAreComplete: true,
            models: [
                VertexAIOnlineServingModelSummary(
                    modelUserID: "claude-sonnet-4-5@20250929",
                    location: "us-east5",
                    publisher: "anthropic",
                    requestType: "shared",
                    invocations: 30,
                    inputTokens: 120_000,
                    outputTokens: 40000,
                    estimatedCostUSD: 0.96,
                    tokensAreComplete: true),
                VertexAIOnlineServingModelSummary(
                    modelUserID: "gemini-2.5-pro",
                    location: "us-central1",
                    publisher: "google",
                    requestType: "shared",
                    invocations: 12,
                    inputTokens: 30000,
                    outputTokens: 10000,
                    estimatedCostUSD: 0.52,
                    tokensAreComplete: true),
            ])
        let response = VertexAIUsageResponse(
            requestsUsedPercent: 45,
            tokensUsedPercent: nil,
            resetsAt: nil,
            resetDescription: nil,
            rawData: nil,
            rateQuotas: [rateBucket],
            allocationQuotas: [allocBucket],
            highestRateQuota: rateBucket,
            highestAllocationQuota: allocBucket,
            totalExceededCount: 0,
            onlineServingSummary: serving)
        let snapshot = VertexAIOAuthFetchStrategy.mapUsage(
            response,
            credentials: credentials,
            settings: VertexAIProviderSettings(primaryBarMetric: .rateQuota, estimateCloudCost: true))

        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let model = try UsageMenuCardView.Model.make(.init(
                provider: .vertexai,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.vertexai]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: "apresai"),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .absolute,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                usesLiveSubtitle: false,
                now: now))
            let view = AnyView(UsageMenuCardView(model: model, width: 360)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: directory.appendingPathComponent("vertex-ai-parity-card.png"))
        }
    }
}
