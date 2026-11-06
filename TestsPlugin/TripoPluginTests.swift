import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct TripoPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `available credits do not subtract frozen reservations or invent a quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine)
        #expect(usage.detailRow(label: "Balance")?.value == "125.75")
        #expect(usage.detailRow(label: "Reserved")?.value == "20.25")
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity == nil)
        let zero = try await Self.fetch(engine, body: #"{"code":0,"data":{"balance":0,"frozen":0}}"#)
        #expect(zero.detailRow(label: "Balance")?.value == "0")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid balance responses fail without exposing their contents`(engine: ProviderPluginEngineKind) async {
        for body in [
            "not-json", "[]", "{}", #"{"code":0,"data":[]}"#,
            #"{"code":false,"data":{"balance":100,"frozen":0}}"#,
            #"{"code":0,"data":{"frozen":0}}"#,
            #"{"code":0,"data":{"balance":null,"frozen":0}}"#,
            #"{"code":0,"data":{"balance":100,"frozen":"private-response-marker"}}"#,
            #"{"code":0,"data":{"balance":100}}"#,
            #"{"code":0,"data":{"balance":"100","frozen":0}}"#,
            #"{"code":0,"data":{"balance":true,"frozen":0}}"#,
            #"{"code":0,"data":{"balance":-1,"frozen":0}}"#,
            #"{"code":0,"data":{"balance":100,"frozen":-1}}"#,
            #"{"code":0,"data":{"balance":1e309,"frozen":0}}"#,
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
                "Tripo request failed. Try refreshing later.": "Localized fixture failure.",
            ])
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .providerUnavailable &&
                error.localizedDescription == "Localized fixture failure."
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an API error envelope remains an API failure`(engine: ProviderPluginEngineKind) async {
        await #expect {
            try await Self.fetch(engine, body: #"{"code":1,"message":"private-response-marker"}"#)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .apiFailure &&
                !error.localizedDescription.contains("private-response-marker")
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        body: String = #"{"code":0,"data":{"balance":125.75,"frozen":20.25}}"#,
        status: Int = 200,
        messages: [String: String] = [:]) async throws -> UsageSnapshot
    {
        let calls = RequestCount()
        let runtime = try BundledPluginTestSupport.runtime(
            "tripo", engine: engine, transport: ProviderHTTPTransportHandler { request in
                await calls.increment()
                #expect(request.url?.absoluteString == "https://openapi.tripo3d.ai/v3/account/balance")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tripo_fixture")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        #expect(runtime.manifest.endpoints == [.fixed("https://openapi.tripo3d.ai")])
        #expect(runtime.manifest.capabilities == [.httpStatus])
        do {
            let usage = try await runtime.fetchUsage(
                settings: ["MESSAGES": String(decoding: JSONEncoder().encode(messages), as: UTF8.self)],
                secrets: ["TRIPO_API_KEY": "tripo_fixture"])
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
