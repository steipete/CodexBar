import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AbliterationPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `contract response yields USD balance and a cumulative meter without reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine)
        #expect(abs((usage.primary?.usedPercent ?? -1) - 0.021274) < 0.000001)
        #expect(usage.primary?.resetDescription == "$0.01 / $50.00")
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.detailRow(label: "Balance")?.value == "$49.99")
        #expect(usage.detailRow(label: "Credits used")?.value == "$0.01")
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero usage overspending and zero credits preserve honest amounts`(
        engine: ProviderPluginEngineKind) async throws
    {
        let unused = try await Self.fetch(engine, body: #"{"data":{"total_credits":50,"total_usage":0}}"#)
        #expect(unused.primary?.usedPercent == 0)
        #expect(unused.detailRow(label: "Balance")?.value == "$50.00")
        let overspent = try await Self.fetch(engine, body: #"{"data":{"total_credits":50,"total_usage":60}}"#)
        #expect(overspent.primary?.usedPercent == 100)
        #expect(overspent.detailRow(label: "Balance")?.value == "$0.00")
        #expect(overspent.detailRow(label: "Credits used")?.value == "$60.00")
        for used in [0, 1] {
            let zero = try await Self.fetch(engine, body: "{\"data\":{\"total_credits\":0,\"total_usage\":\(used)}}")
            #expect(zero.primary == nil)
            #expect(zero.detailRow(label: "Balance")?.value == "$0.00")
            #expect(zero.detailRow(label: "Credits")?.value == "$0.00")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed counters fail closed without disclosing the response`(engine: ProviderPluginEngineKind) async {
        for body in [
            "not-json", "[]", "{}", #"{"data":[]}"#,
            #"{"data":{"total_credits":50}}"#,
            #"{"data":{"total_credits":"50","total_usage":0}}"#,
            #"{"data":{"total_credits":null,"total_usage":0}}"#,
            #"{"data":{"total_credits":-1,"total_usage":0}}"#,
            #"{"data":{"total_credits":50,"total_usage":-1}}"#,
            #"{"data":{"total_credits":50,"total_usage":true}}"#,
            #"{"data":{"total_credits":1e309,"total_usage":0}}"#,
        ] {
            await #expect {
                try await Self.fetch(engine, body: body)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == .parseFailure
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors use classified recovery and never retry within a refresh`(
        engine: ProviderPluginEngineKind) async
    {
        for status in [401, 403, 429, 500, 404] {
            let kind: ProviderFetchClassifiedError.Kind = switch status {
            case 401, 403: .authenticationExpired
            case 429: .rateLimited
            case 500: .providerUnavailable
            default: .apiFailure
            }
            await #expect {
                try await Self.fetch(engine, body: "private-response-marker", status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind &&
                    !error.localizedDescription.contains("private-response-marker") &&
                    (status > 403 || error.localizedDescription.contains("Check your API key in Settings."))
            }
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        body: String = #"{"data":{"total_credits":50.0,"total_usage":0.010637}}"#,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let calls = RequestCount()
        let runtime = try BundledPluginTestSupport.runtime(
            "abliteration", engine: engine, transport: ProviderHTTPTransportHandler { request in
                await calls.increment()
                #expect(request.url?.absoluteString == "https://api.abliteration.ai/v1/credits")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abl_fixture")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        #expect(runtime.manifest.endpoints == [.fixed("https://api.abliteration.ai")])
        #expect(runtime.manifest.capabilities == [.httpStatus])
        do {
            let usage = try await runtime.fetchUsage(secrets: ["ABLITERATION_API_KEY": "abl_fixture"])
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
