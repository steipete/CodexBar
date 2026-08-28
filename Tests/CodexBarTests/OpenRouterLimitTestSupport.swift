import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

enum OpenRouterLimitTestSupport {
    static let now = Date(timeIntervalSince1970: 1_787_079_600)
    static let keyBody = #"""
    {"data":{"limit":30,"limit_remaining":30,"limit_reset":"monthly","usage":0,"usage_monthly":0}}
    """#

    static func snapshot(
        engine: ProviderPluginEngineKind = .quickJS,
        keyBody: String = Self.keyBody,
        keyStatus: Int = 200) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let body: String
            let statusCode: Int
            switch request.url?.absoluteString {
            case "https://openrouter.ai/api/v1/credits":
                body = #"{"data":{"total_credits":5,"total_usage":3.10}}"#
                statusCode = 200
            case "https://openrouter.ai/api/v1/key":
                body = keyBody
                statusCode = keyStatus
            default:
                Issue.record("Unexpected OpenRouter fixture request: \(String(describing: request.url))")
                throw URLError(.unsupportedURL)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        return try await BundledPluginTestSupport.runtime("openrouter", engine: engine, transport: transport)
            .fetchUsage(secrets: ["OPENROUTER_API_KEY": "fixture-key"], now: Self.now)
    }

    @MainActor
    static func model(_ snapshot: UsageSnapshot, showUsed: Bool = false) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        return UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            preferredCurrencyCode: "USD",
            now: Self.now))
    }
}
