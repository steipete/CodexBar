import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite
struct MistralPartialBillingTests {
    private static let header = "ory_session_test=synthetic; csrftoken=synthetic-csrf"
    private static let creditsJSON = #"{"wallet_amount":40,"ongoing_usage_balance":5,"currency":"EUR"}"#

    @Test(arguments: [200, 404, 410, 500])
    func `unavailable billing preserves same-session allowances and credits but not spend`(status: Int) async throws {
        let html = try Self.subscriptionHTML()
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == Self.header)
            #expect(request.url?.host == "admin.mistral.ai")
            switch request.url?.path {
            case "/api/billing/v2/usage":
                return try Self.response(request, status: status, body: #"{"detail":"synthetic-private-body"}"#)
            case "/subscription":
                return try Self.response(request, status: 200, body: html)
            case "/api/billing/credits":
                return try Self.response(request, status: 200, body: Self.creditsJSON)
            default:
                Issue.record("Unexpected Mistral request")
                throw URLError(.unsupportedURL)
            }
        }

        let result = try await MistralWebFetchStrategy(transport: transport).fetch(Self.context())

        #expect(result.usage.primary?.usedPercent == 20)
        #expect(result.usage.extraRateWindows?.first { $0.id == "mistral-monthly-plan" }?.window.usedPercent == 37)
        #expect(result.usage.details.first?.rows.first?.usageValue == 35)
        #expect(result.usage.mistralUsage == nil)
        #expect(result.usage.providerCost == nil)
        #expect(result.usage.costUsage == nil)
        #expect(result.usage.identity == nil)
        let message = try #require(result.diagnostic)
        #expect(!message.contains("synthetic-private-body"))
        #expect(message.contains(status == 200 ? "billing response was not usable" : "HTTP \(status)"))
    }

    @Test
    func `a verified credit balance alone works without a request to the console origin`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            switch request.url?.path {
            case "/api/billing/v2/usage": try Self.response(request, status: 502)
            case "/subscription": try Self.response(request, status: 404)
            case "/api/billing/credits": try Self.response(request, status: 200, body: Self.creditsJSON)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let result = try await MistralWebFetchStrategy(transport: transport).fetch(Self.context())
        #expect(result.usage.primary == nil)
        #expect(result.usage.extraRateWindows?.isEmpty != false)
        #expect(result.usage.details.first?.title == "Credits")
        #expect(result.usage.details.first?.rows.first?.usageValue == 35)
        #expect(result.diagnostic?.contains("HTTP 502") == true)
    }

    @Test
    func `an unverified session never publishes an empty replacement report`() async {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.host == "admin.mistral.ai")
            return try Self.response(request, status: request.url?.path == "/api/billing/v2/usage" ? 500 : 404)
        }
        await #expect {
            try await MistralWebFetchStrategy(transport: transport).fetch(Self.context())
        } throws: { error in
            if case MistralUsageError.httpStatus(500) = error { return true }
            return false
        }
    }

    @Test(arguments: [302, 401, 403, 429])
    func `auth and rate-limit failures do not start supplemental browser requests`(status: Int) async {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.path == "/api/billing/v2/usage")
            let location = status == 302 ? "https://auth.mistral.ai/self-service/login/browser" : nil
            return try Self.response(request, status: status, location: location)
        }
        await #expect {
            try await MistralWebFetchStrategy(transport: transport).fetch(Self.context())
        } throws: { error in
            switch error {
            case MistralUsageError.httpStatus(429): status == 429
            case MistralUsageError.invalidCredentials: status != 429
            default: false
            }
        }
    }

    private static func subscriptionHTML() throws -> String {
        let api = #"{"usage_percentage":20,"initial_budget":100,"currency":"EUR"}"#
        let vibe = #"{"usage_percentage":37,"initial_budget":200,"currency":"EUR"}"#
        let row = "7:{\"budget\":{\"api_budget\":\(api),\"vibe_budget\":\(vibe)}}\n"
        let data = try JSONSerialization.data(withJSONObject: [1, row])
        let push = try #require(String(bytes: data, encoding: .utf8))
        return "<script>self.__next_f.push(\(push))</script>"
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        location: String? = nil,
        body: String = "") throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let headers = location.map { ["Location": $0] }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers))
        return (Data(body.utf8), response)
    }

    @Test
    func `allowance-only snapshots are marked unavailable for spend analytics`() {
        let now = Date()
        let allowanceOnly = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "$4 / $10"),
            secondary: nil,
            updatedAt: now)
        #expect(MistralProviderDescriptor.descriptor.tokenCost.isUsageUnavailable(allowanceOnly))

        let emptyBilling = MistralUsageSnapshot(
            totalCost: 0,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            startDate: nil,
            endDate: nil,
            updatedAt: now).toUsageSnapshot()
        #expect(MistralProviderDescriptor.descriptor.tokenCost.isUsageUnavailable(emptyBilling) == false)
    }

    private static func context() -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 2,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(mistral: .init(cookieSource: .manual, manualCookieHeader: self.header)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }
}
