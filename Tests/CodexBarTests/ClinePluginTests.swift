import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClinePluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance fixture maps cents to dollars with identity`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "cline",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = request.url?.absoluteString ?? ""
                if url.hasSuffix("/api/v1/users/me") {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
                    return try Self.response(
                        request,
                        body: #"{"success":true,"data":{"id":"user-1","email":"user@example.com"}}"#)
                }
                #expect(url == "https://api.cline.bot/api/v1/users/user-1/balance")
                return try Self.response(
                    request,
                    body: #"{"success":true,"data":{"balance":1234,"userId":"user-1"}}"#)
            })

        let snapshot = try await runtime.fetchUsage(
            settings: ["CLINE_AUTH_SOURCE": "api"],
            secrets: ["CLINE_API_KEY": "test-key"])

        #expect(snapshot.identity?.email == "user@example.com")
        #expect(snapshot.identity?.loginMethod == "API key")
        let rows = snapshot.details?.first?.rows ?? []
        #expect(rows.count == 1)
        #expect(rows.first?.label == "Available balance")
        // 1234 cents → $12.34
        #expect(rows.first?.value.contains("12.34") == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `browser session reports browser login method`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "cline",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = request.url?.absoluteString ?? ""
                if url.hasSuffix("/api/v1/users/me") {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer workos:browser-token")
                    return try Self.response(
                        request,
                        body: #"{"success":true,"data":{"id":"user-9","email":"browser@example.com"}}"#)
                }
                return try Self.response(
                    request,
                    body: #"{"success":true,"data":{"balance":500,"userId":"user-9"}}"#)
            })

        let snapshot = try await runtime.fetchUsage(
            settings: ["CLINE_AUTH_SOURCE": "oauth"],
            secrets: ["CLINE_API_KEY": "workos:browser-token"])

        #expect(snapshot.identity?.loginMethod == "Browser")
        #expect(snapshot.identity?.email == "browser@example.com")
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
            "cline",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: "{}", status: status)
            })
        do {
            _ = try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            if status == 401 || status == 403 {
                #expect(error.message.contains("Cline credentials were rejected."))
            } else {
                #expect(error.message.contains("HTTP \(status)"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed balance is a classified parse failure`(engine: ProviderPluginEngineKind) async {
        let runtime: ProviderPluginRuntime
        do {
            runtime = try BundledPluginTestSupport.runtime(
                "cline",
                engine: engine,
                transport: ProviderHTTPTransportHandler { request in
                    let url = request.url?.absoluteString ?? ""
                    if url.hasSuffix("/api/v1/users/me") {
                        return try Self.response(
                            request,
                            body: #"{"success":true,"data":{"id":"user-1","email":"a@b.com"}}"#)
                    }
                    return try Self.response(
                        request,
                        body: #"{"success":true,"data":{"balance":"many"}}"#)
                })
        } catch {
            Issue.record("Unexpected setup error: \(error)")
            return
        }
        do {
            _ = try await runtime.fetchUsage(secrets: ["CLINE_API_KEY": "test-key"])
            Issue.record("Expected parseFailure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message.contains("Failed to parse Cline balance response"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `descriptor is balance only with api source modes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .cline)
        #expect(descriptor.metadata.balanceOnly == true)
        #expect(descriptor.metadata.displayName == "Cline")
        #expect(descriptor.metadata.cliName == "cline")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-cline")
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
}
