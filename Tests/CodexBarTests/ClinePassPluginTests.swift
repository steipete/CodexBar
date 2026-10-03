import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClinePassPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `browser session reaches quota parser on both engines`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer workos:fixture-session")
                return try Self.response(
                    request, body: #"{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":25}]}}"#)
            })
        let snapshot = try await runtime.fetchUsage(
            settings: ["CLINE_AUTH_SOURCE": "oauth"], secrets: ["CLINE_API_KEY": "workos:fixture-session"])
        #expect(snapshot.identity?.loginMethod == "Browser")
        #expect(snapshot.secondary?.usedPercent == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected browser session explains manual renewal without disclosing secrets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass", engine: engine, transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: #"{"error":"workos:fixture-session"}"#, status: 401)
            })
        do {
            _ = try await runtime.fetchUsage(
                settings: ["CLINE_AUTH_SOURCE": "oauth"], secrets: ["CLINE_API_KEY": "workos:fixture-session"])
            Issue.record("Expected rejected session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("cline auth"))
            #expect(!error.message.contains("fixture-session"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `all rate-window fixture matches the production golden`(engine: ProviderPluginEngineKind) async throws {
        let body = #"""
        {
          "data": {
            "limits": [
              { "type": "five_hour", "percentUsed": 12.5, "resetsAt": "2026-07-16T10:20:30Z" },
              { "type": "weekly", "percentUsed": 34, "resetsAt": "2026-07-20T00:00:00Z" },
              { "type": "monthly", "percentUsed": 56.75, "resetsAt": "2026-08-01T00:00:00Z" }
            ]
          },
          "success": true
        }
        """#
        let snapshot = try await Self.fetch(body, engine: engine)

        #expect(snapshot.primary == RateWindow(
            usedPercent: 12.5,
            windowMinutes: 300,
            resetsAt: Self.date("2026-07-16T10:20:30Z"),
            resetDescription: nil))
        #expect(snapshot.secondary == RateWindow(
            usedPercent: 34,
            windowMinutes: 10080,
            resetsAt: Self.date("2026-07-20T00:00:00Z"),
            resetDescription: nil))
        #expect(snapshot.tertiary == RateWindow(
            usedPercent: 56.75,
            windowMinutes: 43200,
            resetsAt: Self.date("2026-08-01T00:00:00Z"),
            resetDescription: nil))
        #expect(snapshot.identity?.providerID == .clinepass)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unknown limits are ignored without dropping known windows`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "success": true,
          "data": {
            "limits": [
              { "type": "five_hour", "percentUsed": 12.5, "resetsAt": "2026-07-16T15:00:00Z" },
              { "type": "experimental_pool", "percentUsed": 77, "resetsAt": "2026-07-16T15:00:00Z" },
              { "type": "weekly", "percentUsed": 25, "resetsAt": "2026-07-20T00:00:00Z" },
              { "type": "monthly", "percentUsed": 40, "resetsAt": null }
            ]
          }
        }
        """#, engine: engine)

        #expect(snapshot.primary?.usedPercent == 12.5)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.tertiary?.usedPercent == 40)
        #expect(snapshot.tertiary?.resetsAt == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `request uses bearer auth and production deadline`(engine: ProviderPluginEngineKind) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/api/v1/users/me") {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
                return try Self.response(
                    request,
                    body: #"{"success":true,"data":{"id":"user-1","email":"user@example.com"}}"#)
            }
            if url.contains("/balance") {
                return try Self.response(
                    request,
                    body: #"{"success":true,"data":{"balance":1234,"userId":"user-1"}}"#)
            }
            #expect(url == "https://api.cline.bot/api/v1/users/me/plan/usage-limits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return try Self.response(
                request,
                body: #"{"data":{"limits":[{"type":"weekly","percentUsed":40}]},"success":true}"#)
        }
        let runtime = try BundledPluginTestSupport.runtime("clinepass", engine: engine, transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.tertiary == nil)
        // 1234 cents of pay-as-you-go credit surfaces as a detail row.
        let rows = snapshot.details?.first?.rows ?? []
        #expect(rows.count == 1)
        #expect(rows.first?.label == "Available balance")
        #expect(rows.first?.value.contains("12.34") == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `direct account and balance payloads are accepted`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = request.url?.absoluteString ?? ""
                if url.hasSuffix("/api/v1/users/me") {
                    return try Self.response(request, body: #"{"id":"user-7","email":"direct@example.com"}"#)
                }
                if url.contains("/balance") {
                    return try Self.response(request, body: #"{"balance":250,"userId":"user-7"}"#)
                }
                return try Self.response(
                    request,
                    body: #"{"data":{"limits":[{"type":"weekly","percentUsed":40}]},"success":true}"#)
            })

        let snapshot = try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.details?.first?.title == "Cline credits")
        #expect(snapshot.details?.first?.rows.first?.value.contains("2.50") == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance failure keeps quota windows`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = request.url?.absoluteString ?? ""
                if url.hasSuffix("/api/v1/users/me") || url.contains("/balance") {
                    return try Self.response(request, body: "{}", status: 500)
                }
                return try Self.response(
                    request,
                    body: #"{"data":{"limits":[{"type":"weekly","percentUsed":40}]},"success":true}"#)
            })

        let snapshot = try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.details == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `transport cancellation remains cancellation`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) {
            try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (429, .rateLimited),
        (500, .providerUnavailable),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures preserve classified surfaces`(
        argument: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async throws
    {
        let (status, kind) = argument
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: "{}", status: status)
            })
        await Self.expectFailure(
            kind,
            contains: status == 401 || status == 403
                ? "ClinePass credentials were rejected."
                : "ClinePass API error: HTTP \(status)")
        {
            try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed payload is a classified parse failure`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure, contains: "Failed to parse ClinePass response") {
            try await Self.fetch(
                #"{"data":{"limits":[{"type":"weekly","percentUsed":"forty"}]},"success":true}"#,
                engine: engine)
        }
    }

    @Test
    func `descriptor is script-only and credential aliases keep precedence`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .clinepass)
        let environment = [ClinePassSettingsReader.alternateAPIKeyEnvironmentKey: "test-key"]
        let context = Self.context(environment: environment)
        let strategy = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first)

        #expect(strategy.id == "clinepass.js")
        #expect(await strategy.isAvailable(context))
        #expect(ClinePassSettingsReader.apiKey(environment: environment) == "test-key")
    }

    private static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "clinepass",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body)
            })
        return try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func date(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        contains message: String,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(error.message.contains(message))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func context(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClinePassPluginClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private struct ClinePassPluginClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? {
        nil
    }

    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }
}
