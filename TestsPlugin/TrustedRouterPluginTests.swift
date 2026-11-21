import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TrustedRouterPluginTests {
    /// Redacted `GET /v1/key` sample from the public TrustedRouter response documentation.
    private static let limitedKey = """
    {"data":{"hash":"<key-hash>","name":"example","label":"sk-tr-v1-a...wxyz","disabled":false,\
    "limit":10,"limit_microdollars":10000000,"limit_remaining":6.6,"limit_remaining_microdollars":6600000,\
    "limit_reset":"monthly","include_byok_in_limit":true,"usage":3.25,"usage_microdollars":3250000,\
    "usage_daily":0.4,"usage_daily_microdollars":400000,"usage_weekly":1.1,"usage_weekly_microdollars":1100000,\
    "usage_monthly":3.25,"usage_monthly_microdollars":3250000,"byok_usage":0.0,"byok_usage_microdollars":0,\
    "reserved_microdollars":150000,"expires_at":null,"management":false}}
    """

    private static func key(limit: String, remaining: String, usage: String = "3250000") -> String {
        """
        {"data":{"limit_microdollars":\(limit),"limit_remaining_microdollars":\(remaining),\
        "usage_microdollars":\(usage),"usage_daily_microdollars":400000,\
        "usage_weekly_microdollars":1100000,"usage_monthly_microdollars":3250000}}
        """
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `limited key shows reservation aware remaining amount and spend windows`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine)
        #expect(abs((usage.primary?.usedPercent ?? -1) - 34) < 0.000001)
        #expect(usage.primary?.resetDescription == "$3.40 / $10.00")
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.detailRow(label: "Remaining")?.value == "$6.60")
        #expect(usage.detailRow(label: "Limit")?.value == "$10.00")
        #expect(usage.detailRow(label: "Today")?.value == "$0.40")
        #expect(usage.detailRow(label: "This week")?.value == "$1.10")
        #expect(usage.detailRow(label: "This month")?.value == "$3.25")
        #expect(usage.detailRow(label: "Total usage")?.value == "$3.25")
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unlimited and exhausted keys keep honest amounts`(engine: ProviderPluginEngineKind) async throws {
        let unlimited = try await Self.fetch(engine, body: Self.key(limit: "null", remaining: "null"))
        #expect(unlimited.primary == nil)
        #expect(unlimited.detailRow(label: "Remaining") == nil)
        #expect(unlimited.detailRow(label: "Limit") == nil)
        #expect(unlimited.detailRow(label: "Total usage")?.value == "$3.25")
        let exhausted = try await Self.fetch(engine, body: Self.key(limit: "10000000", remaining: "0"))
        #expect(exhausted.primary?.usedPercent == 100)
        #expect(exhausted.detailRow(label: "Remaining")?.value == "$0.00")
        let zero = try await Self.fetch(engine, body: Self.key(limit: "0", remaining: "0"))
        #expect(zero.primary == nil)
        #expect(zero.detailRow(label: "Remaining")?.value == "$0.00")
        #expect(zero.detailRow(label: "Limit")?.value == "$0.00")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed key responses fail closed without disclosing the response`(
        engine: ProviderPluginEngineKind) async
    {
        for body in [
            "not-json", "[]", "{}", #"{"data":[]}"#,
            #"{"data":{"usage":3.25,"usage_daily":0.4,"usage_weekly":1.1,"usage_monthly":3.25}}"#,
            Self.key(limit: "10000000", remaining: "null"),
            Self.key(limit: "null", remaining: "null").replacingOccurrences(
                of: "\"limit_microdollars\":null,",
                with: ""),
            Self.key(limit: "null", remaining: "6600000"),
            Self.key(limit: "\"10000000\"", remaining: "6600000"),
            Self.key(limit: "10000000", remaining: "-1"),
            Self.key(limit: "10000000", remaining: "6600000.5"),
            Self.key(limit: "10000000", remaining: "6600000", usage: "\"private-response-marker\""),
            Self.key(limit: "10000000", remaining: "6600000", usage: "true"),
            Self.key(limit: "10000000", remaining: "6600000", usage: "1e309"),
        ] {
            await #expect {
                try await Self.fetch(engine, body: body)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == .parseFailure &&
                    !error.localizedDescription.contains("private-response-marker")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures are classified without retrying or exposing server messages`(
        engine: ProviderPluginEngineKind) async
    {
        for status in [401, 403, 429, 500, 404] {
            let kind: ProviderFetchClassifiedError.Kind = switch status {
            case 401: .authenticationExpired
            case 403: .permissionDenied
            case 429: .rateLimited
            case 500: .providerUnavailable
            default: .apiFailure
            }
            await #expect {
                try await Self.fetch(engine, body: "private-response-marker", status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind &&
                    !error.localizedDescription.contains("private-response-marker")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `diagnostics use the host supplied translation`(engine: ProviderPluginEngineKind) async {
        await #expect {
            try await Self.fetch(engine, status: 500, messages: [
                "TrustedRouter request failed. Try refreshing later.": "Localized fixture failure.",
            ])
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .providerUnavailable &&
                error.localizedDescription == "Localized fixture failure."
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        body: String = Self.limitedKey,
        status: Int = 200,
        messages: [String: String] = [:]) async throws -> UsageSnapshot
    {
        let calls = RequestCount()
        let runtime = try BundledPluginTestSupport.runtime(
            "trustedrouter", engine: engine, transport: ProviderHTTPTransportHandler { request in
                await calls.increment()
                #expect(request.url?.absoluteString == "https://api.trustedrouter.com/v1/key")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tr_fixture")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        #expect(runtime.manifest.endpoints == [.fixed("https://api.trustedrouter.com")])
        #expect(runtime.manifest.capabilities == [.httpStatus])
        do {
            let usage = try await runtime.fetchUsage(
                settings: ["MESSAGES": String(decoding: JSONEncoder().encode(messages), as: UTF8.self)],
                secrets: ["TRUSTEDROUTER_API_KEY": "tr_fixture"])
            #expect(await calls.value == 1)
            return usage
        } catch {
            #expect(await calls.value == 1)
            throw error
        }
    }

    private actor RequestCount {
        var value = 0
        func increment() { self.value += 1 }
    }
}
