import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SiliconFlowPluginTests {
    private static let contract = """
    {"code":20000,"message":"OK","status":true,"data":{"id":"user","name":"hidden",
    "email":"hidden@example.com","balance":"0.88","status":"normal",
    "chargeBalance":"88.00","totalBalance":"88.88"}}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `contract response shows CNY total without a quota or identity`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.identity == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.detailRow(label: "Total balance")?.value == "CN¥88.88")
        #expect(usage.detailRow(label: "Charged balance")?.value == "CN¥88.00")
        #expect(usage.detailRow(label: "Bonus balance")?.value == "CN¥0.88")
        #expect(usage.detailRow(label: "Account status") == nil)
        #expect(!Self.text(usage).contains("hidden@example.com"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `international origin uses USD and keeps a negative overdue total`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = """
        {"code":20000,"status":true,"data":{"balance":"0.00","chargeBalance":"0.00",
        "totalBalance":"-1.50","status":"overdue"}}
        """
        let usage = try await Self.fetch(engine, body: body, origin: "https://api.siliconflow.com")
        #expect(usage.detailRow(label: "Total balance")?.value == "-$1.50")
        #expect(usage.detailRow(label: "Account status")?.value == "overdue")
        #expect(usage.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed counters and foreign origins fail closed`(engine: ProviderPluginEngineKind) async {
        for body in [
            "not-json",
            "[]",
            "{}",
            #"{"code":20000,"status":true,"data":{}}"#,
            #"{"code":20000,"status":true,"data":{"totalBalance":"88.88.1"}}"#,
            #"{"code":20000,"status":false,"data":{"totalBalance":"1"}}"#,
            #"{"code":1,"status":true,"data":{"totalBalance":"1"}}"#,
            #"{"code":20000,"status":true,"data":{"totalBalance":"1e2","balance":"0","chargeBalance":"0"}}"#,
        ] {
            await #expect {
                try await Self.fetch(engine, body: body)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == .parseFailure &&
                    !error.localizedDescription.contains("hidden")
            }
        }
        await #expect {
            try await Self.fetch(engine, origin: "https://evil.example")
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .apiFailure
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `auth rate limit and retired query stay classified without the body`(
        engine: ProviderPluginEngineKind) async
    {
        let cases: [(Int, String, ProviderFetchClassifiedError.Kind)] = [
            (401, #"{"code":30014,"message":"private-response-marker"}"#, .authenticationExpired),
            (403, "private-response-marker", .authenticationExpired),
            (429, "private-response-marker", .rateLimited),
            (410, #"{"code":20092,"message":"private-response-marker"}"#, .providerUnavailable),
            (500, "private-response-marker", .providerUnavailable),
            (404, "private-response-marker", .apiFailure),
        ]
        for (status, body, kind) in cases {
            await #expect {
                try await Self.fetch(engine, body: body, status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind &&
                    !error.localizedDescription.contains("private-response-marker")
            }
        }
        await #expect {
            try await Self.fetch(engine, body: #"{"code":20092,"status":false,"message":"private-response-marker"}"#)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .providerUnavailable &&
                !error.localizedDescription.contains("private-response-marker")
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        body: String = Self.contract,
        status: Int = 200,
        origin: String = "https://api.siliconflow.cn") async throws -> UsageSnapshot
    {
        let calls = RequestCount()
        let runtime = try BundledPluginTestSupport.runtime(
            "siliconflow", engine: engine, transport: ProviderHTTPTransportHandler { request in
                await calls.increment()
                #expect(request.url?.absoluteString == "\(origin)/v1/user/info")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-fixture")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        #expect(runtime.manifest.endpoints == [
            .fixed("https://api.siliconflow.cn"),
            .fixed("https://api.siliconflow.com"),
        ])
        do {
            let usage = try await runtime.fetchUsage(
                settings: ["SILICONFLOW_BASE_URL": origin],
                secrets: ["SILICONFLOW_API_KEY": "sk-fixture"])
            #expect(await calls.value == 1)
            return usage
        } catch {
            #expect(await calls.value == (origin == "https://evil.example" ? 0 : 1))
            throw error
        }
    }

    private static func text(_ usage: UsageSnapshot) -> String {
        usage.details.flatMap(\.rows).map(\.value).joined(separator: " ")
    }

    private actor RequestCount {
        var value = 0
        func increment() { self.value += 1 }
    }
}
