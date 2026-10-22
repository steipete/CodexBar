import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct TraeCNPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let cookie = "sessionid=fixture-session"
    private static let fixture = #"""
    {"is_credits_billing":true,"usage_summary":{"total_amount":10000,"consumed_amount":2000},
    "user_entitlement_pack_list":[
      {"group_type":0,"status":1,"display_desc":"Fixture Pro","expire_time":2000000000,"next_billing_time":1900000000},
      {"group_type":4,"status":1,"expire_time":1850000000}]}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `credit summary does not invent reset or renewal dates`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(engine: engine)
        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.subscriptionExpiresAt == nil)
        #expect(usage.identity?.providerID == .traecn)
        #expect(usage.identity?.loginMethod == "Fixture Pro")
        #expect(usage.details.first?.rows.map(\.value) == ["2,000", "10,000", "8,000"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero credits remain visible without a fabricated quota`(engine: ProviderPluginEngineKind) async throws {
        let body = #"{"is_credits_billing":true,"usage_summary":{"total_amount":0,"consumed_amount":0}}"#
        let usage = try await Self.fetch(body: body, engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.details.first?.rows.map(\.value) == ["0", "0", "0"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid credits and dollar billing do not become zero usage`(engine: ProviderPluginEngineKind) async {
        for body in [
            "null",
            #"{"is_credits_billing":true,"usage_summary":{"total_amount":100}}"#,
            #"{"is_credits_billing":true,"usage_summary":{"total_amount":100,"consumed_amount":-1}}"#,
            #"{"is_credits_billing":true,"usage_summary":{"total_amount":"100","consumed_amount":1}}"#,
            #"{"is_credits_billing":false,"usage_summary":{"total_amount":100,"consumed_amount":1}}"#,
        ] {
            await CookiePluginFixtures.expectFailure(.parseFailure) {
                try await Self.fetch(body: body, engine: engine)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected sessions are replaced lazily and traversal stops on success`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = LockIsolated<[String]>([])
        let runtime = try Self.runtime(engine: engine, requests: requests)
        let next = LockIsolated(0)
        _ = try await runtime.fetchUsage(
            now: Self.now,
            cookieSource: .auto,
            cookieSessionResolver: { domain, _ in
                #expect(domain == "api.trae.cn")
                let index = next.value
                next.setValue(index + 1)
                let headers = ["rejected=fixture", Self.cookie, "unused=fixture"]
                guard index < headers.count else { return nil }
                return ProviderPluginCookieSession(
                    header: headers[index], source: "Fixture", origin: "https://api.trae.cn")
            })
        #expect(next.value == 2)
        #expect(requests.value.count == 3)
        #expect(!requests.value.contains { $0.contains("unused") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `off cookies never import or contact the API`(engine: ProviderPluginEngineKind) async throws {
        let requests = LockIsolated<[String]>([])
        let runtime = try Self.runtime(engine: engine, requests: requests)
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(cookieSource: .off, cookieResolver: { _, _ in
                Issue.record("Off must not read browser cookies")
                return Self.cookie
            })
        }
        #expect(requests.value.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `API failures retain classification and never echo bodies or tokens`(
        engine: ProviderPluginEngineKind) async
    {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
            (429, .rateLimited),
            (503, .providerUnavailable),
        ] {
            do {
                _ = try await Self.fetch(engine: engine, usageStatus: code)
                Issue.record("Expected classified failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == kind)
                #expect(!error.message.contains("private-response"))
                #expect(!error.message.contains("fixture-jwt"))
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test
    func `provider uses shared cookies and starts disabled`() {
        let descriptor = TraeCNProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
    }

    private static func fetch(
        body: String = Self.fixture,
        engine: ProviderPluginEngineKind,
        usageStatus: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try Self.runtime(engine: engine, body: body, usageStatus: usageStatus)
        return try await runtime.fetchUsage(
            now: Self.now, cookieSource: .manual, cookieResolver: { _, _ in Self.cookie })
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        body: String = Self.fixture,
        usageStatus: Int = 200,
        requests: LockIsolated<[String]> = LockIsolated([])) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "traecn",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                #expect(url.host == "api.trae.cn")
                #expect(request.httpMethod == "POST")
                let path = url.path
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                requests.setValue(requests.value + [path + " " + cookie])
                let isToken = path == "/cloudide/api/v3/common/GetUserToken"
                #expect(isToken || path == "/trae/api/v2/pay/user_current_entitlement_list")
                let status = cookie.hasPrefix("rejected=") ? 401 : (isToken ? 200 : usageStatus)
                if isToken {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                } else {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Cloud-IDE-JWT fixture-jwt")
                    let bodyData = try #require(request.httpBody)
                    let payload = try JSONSerialization.jsonObject(with: bodyData) as? [String: Bool]
                    #expect(payload == ["require_usage": true, "full_data": true])
                }
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                let payload = if status == 200 {
                    isToken ? #"{"Result":{"Token":"fixture-jwt"}}"# : body
                } else {
                    "private-response"
                }
                return (Data(payload.utf8), response)
            })
    }
}
