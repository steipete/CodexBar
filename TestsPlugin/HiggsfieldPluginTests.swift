import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HiggsfieldPluginTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `reported balance leaves limit and renewal unavailable`(engine: ProviderPluginEngineKind) async throws {
        let transport = HiggsfieldMCPTransport(responses: [
            Self.response(
                200,
                Self.initializeResponse(),
                headers: [
                    "Content-Type": "application/json",
                    "MCP-Session-Id": "fixture-session",
                ]),
            Self.response(
                202,
                "",
                headers: [:]),
            Self.response(
                200,
                Self.event(Self.toolsListResponse(name: "balance")),
                headers: [
                    "Content-Type": "text/event-stream",
                ]),
            Self.response(
                200,
                Self.event(Self.balanceResponse()),
                headers: [
                    "Content-Type": "text/event-stream",
                ]),
        ])
        let runtime = try Self.runtime(engine, transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
        let rows = snapshot.details.flatMap(\.rows)

        #expect(rows.first { $0.label == "Available credits" }?.value == "123.5")
        #expect(rows.first { $0.label == "Credit limit" }?.value == Self.unreported)
        #expect(rows.first { $0.label == "Subscription renewal" }?.value == Self.unreported)
        #expect(rows.first { $0.label == "Plan" }?.value == "plus")
        #expect(snapshot.primary == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        if engine == .quickJS {
            let credits = rows.first { $0.label == "Available credits" }?.value ?? "missing"
            let limit = rows.first { $0.label == "Credit limit" }?.value ?? "missing"
            let renewal = rows.first { $0.label == "Subscription renewal" }?.value ?? "missing"
            print("SIMULATED Higgsfield plugin output: credits=\(credits); limit=\(limit); renewal=\(renewal)")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.url == "https://mcp.higgsfield.ai/mcp" })
        #expect(requests.allSatisfy { $0.authorization == "Bearer fixture-token" })
        #expect(requests.allSatisfy { $0.accept == "application/json, text/event-stream" })
        #expect(requests.allSatisfy { $0.acceptEncoding == "identity" })
        #expect(requests.dropFirst().allSatisfy { $0.sessionID == "fixture-session" })
        #expect(requests.dropFirst().allSatisfy { $0.protocolVersion == "2025-11-25" })
        #expect(requests.compactMap(\.method) == [
            "initialize",
            "notifications/initialized",
            "tools/list",
            "tools/call",
        ])
    }

    @Test
    func `installed plugin requires approval and accepts the MCP response types`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-higgsfield-install-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let bundledSource = try String(
            contentsOf: repository.appendingPathComponent("Examples/Plugins/higgsfield.js"),
            encoding: .utf8)
        let userPluginSource = bundledSource.replacingOccurrences(
            of: #"id: "higgsfield-credits""#,
            with: #"id: "fixture-higgsfield""#)
        let download = downloads.appendingPathComponent("higgsfield.js")
        try Data(userPluginSource.utf8).write(to: download)

        let transport = HiggsfieldMCPTransport(responses: [
            Self.response(
                200,
                Self.initializeResponse(),
                headers: ["MCP-Session-Id": "fixture-session"]),
            Self.response(202, "", headers: [:]),
            Self.response(200, Self.toolsListResponse(name: "balance")),
            Self.response(200, Self.balanceResponse()),
        ])
        let loader = UserProviderPluginLoader(
            providersDirectory: providers,
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            transport: transport)
        let plugin = try loader.install(fileURL: download)
        let approvals = ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))

        do {
            _ = try await plugin.fetchUsage(
                settings: [:],
                secrets: ["MCP_ACCESS_TOKEN": "fixture-token"],
                environment: [:],
                approvalStore: approvals,
                sourceMode: .api)
            Issue.record("Expected installation approval to be required")
        } catch let error as UserProviderPluginError {
            #expect(try error == .approvalRequired(plugin.approvalBinding(settings: [:])))
        }
        #expect(await transport.recordedRequests().isEmpty)

        try approvals.record(plugin.approvalBinding(settings: [:]))
        let snapshot = try await plugin.fetchUsage(
            settings: [:],
            secrets: ["MCP_ACCESS_TOKEN": "fixture-token"],
            environment: [:],
            approvalStore: approvals,
            sourceMode: .api)

        #expect(snapshot.details.flatMap(\.rows).first { $0.label == "Available credits" }?.value == "123.5")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.accept == "application/json, text/event-stream" })
        #expect(requests.allSatisfy { $0.acceptEncoding == "identity" })
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `unauthorized and unadvertised tools fail safely`(engine: ProviderPluginEngineKind) async throws {
        let unauthorized = try Self.runtime(
            engine,
            transport: HiggsfieldMCPTransport(responses: [Self.response(401, "private-response-marker")]))
        do {
            _ = try await unauthorized.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
            Issue.record("Expected an authentication error")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(!error.localizedDescription.contains("private-response-marker"))
        }

        let noBalance = try Self.runtime(
            engine,
            transport: HiggsfieldMCPTransport(responses: Self.jsonBalanceResponses(
                call: Self.balanceResponse(),
                toolName: "generate")))
        do {
            _ = try await noBalance.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
            Issue.record("Expected unsupported tool rejection")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .permissionDenied)
            #expect(error.localizedDescription.contains("Update the Higgsfield plugin, then refresh."))
            #expect(!error.localizedDescription.contains("fixture-token"))
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `malformed credit values fail closed`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine,
            transport: HiggsfieldMCPTransport(responses: Self.jsonBalanceResponses(
                call: Self.malformedBalanceResponse())))

        await #expect {
            try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
        } throws: { error in
            guard let classified = error as? ProviderFetchClassifiedError else { return false }
            return classified.kind == .parseFailure &&
                classified.localizedDescription.contains("Update the Higgsfield plugin, then refresh.") &&
                !classified.localizedDescription.contains("private-response-marker") &&
                !classified.localizedDescription.contains("fixture-token")
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `temporary HTTP failures explain recovery without exposing the response`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (status, expectedKind) in [
            (429, ProviderFetchClassifiedError.Kind.rateLimited),
            (503, .providerUnavailable),
        ] {
            let runtime = try Self.runtime(
                engine,
                transport: HiggsfieldMCPTransport(responses: [
                    Self.response(status, "private-response-marker"),
                ]))
            do {
                _ = try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
                Issue.record("Expected the HTTP failure to be classified")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == expectedKind)
                #expect(error.localizedDescription.contains("Wait a few minutes, then refresh."))
                #expect(!error.localizedDescription.contains("private-response-marker"))
                #expect(!error.localizedDescription.contains("fixture-token"))
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `JSON text preserves decimal credits`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine,
            transport: HiggsfieldMCPTransport(responses: Self.jsonBalanceResponses(
                call: Self.textBalanceResponse())))

        let snapshot = try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
        #expect(snapshot.details.flatMap(\.rows).first { $0.label == "Available credits" }?.value == "12.5")
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `tool errors do not display stale balance`(engine: ProviderPluginEngineKind) async throws {
        let toolError = Self.toolErrorResponse()
        let billingError = Self.billingErrorResponse()
        for (body, marker) in [(toolError, "private-tool-error"), (billingError, "private-billing-error")] {
            let runtime = try Self.runtime(engine, transport: HiggsfieldMCPTransport(
                responses: Self.jsonBalanceResponses(call: body)))
            do {
                _ = try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
                Issue.record("Expected a balance retrieval error")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .apiFailure)
                #expect(!error.localizedDescription.contains(marker))
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `unknown protocol version stops before follow-up requests`(engine: ProviderPluginEngineKind) async throws {
        let transport = HiggsfieldMCPTransport(responses: [
            Self.response(
                200,
                Self.initializeResponse(protocolVersion: "2030-private-response-marker"),
                headers: ["MCP-Session-Id": "fixture-session"]),
        ])
        let runtime = try Self.runtime(engine, transport: transport)

        await #expect {
            try await runtime.fetchUsage(secrets: ["MCP_ACCESS_TOKEN": "fixture-token"])
        } throws: { error in
            guard let classified = error as? ProviderFetchClassifiedError else { return false }
            return classified.kind == .providerUnavailable &&
                classified.localizedDescription.contains("Update the Higgsfield plugin, then refresh.") &&
                !classified.localizedDescription.contains("private-response-marker") &&
                !classified.localizedDescription.contains("fixture-token")
        }
        #expect(await transport.recordedRequests().count == 1)
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Examples/Plugins/higgsfield.js"),
            encoding: .utf8)
        return try ProviderPluginRuntime(
            source: source,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            enforcesUserResponsePolicy: true,
            allowsDynamicID: true,
            engine: engine)
    }

    private static func response(
        _ status: Int,
        _ body: String,
        headers: [String: String] = ["Content-Type": "application/json"]) -> HiggsfieldMCPTransport.Response
    {
        HiggsfieldMCPTransport.Response(status: status, body: body, headers: headers)
    }

    private static let unreported = "Not reported by the balance tool"

    private static func initializeResponse(protocolVersion: String = "2025-11-25") -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["protocolVersion": protocolVersion],
        ])
    }

    private static func toolsListResponse(name: String) -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["tools": [["name": name]]],
        ])
    }

    private static func balanceResponse() -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["structuredContent": ["credits": 123.5, "subscription_plan_type": "plus"]],
        ])
    }

    private static func malformedBalanceResponse() -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["structuredContent": ["credits": "private-response-marker"]],
        ])
    }

    private static func textBalanceResponse() -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["content": [["type": "text", "text": #"{"credits":12.5}"#]]],
        ])
    }

    private static func toolErrorResponse() -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["isError": true, "content": [["type": "text", "text": "private-tool-error"]]],
        ])
    }

    private static func billingErrorResponse() -> String {
        self.json([
            "jsonrpc": "2.0",
            "id": 3,
            "result": ["structuredContent": ["credits": 0, "error": "private-billing-error"]],
        ])
    }

    private static func jsonBalanceResponses(
        call: String,
        toolName: String = "balance") -> [HiggsfieldMCPTransport.Response]
    {
        [
            self.response(
                200,
                self.initializeResponse(),
                headers: ["MCP-Session-Id": "fixture-session"]),
            self.response(202, "", headers: [:]),
            self.response(200, self.toolsListResponse(name: toolName)),
            self.response(200, call),
        ]
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func event(_ data: String) -> String {
        let lines = data.split(separator: "\n").map { "data: \($0)" }.joined(separator: "\n")
        return "event: message\n\(lines)\n\n"
    }
}

private actor HiggsfieldMCPTransport: ProviderHTTPTransport {
    private static let requiredAccept = "application/json, text/event-stream"

    struct Response: Sendable {
        let status: Int
        let body: String
        let headers: [String: String]
    }

    struct Request: Sendable {
        let url: String?
        let authorization: String?
        let accept: String?
        let acceptEncoding: String?
        let sessionID: String?
        let protocolVersion: String?
        let method: String?
    }

    private var responses: [Response]
    private var requests: [Request] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.value(forHTTPHeaderField: "Accept") == Self.requiredAccept,
              request.value(forHTTPHeaderField: "Accept-Encoding") == "identity"
        else { throw URLError(.unsupportedURL) }
        guard !self.responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = self.responses.removeFirst()
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.requests.append(Request(
            url: request.url?.absoluteString,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding"),
            sessionID: request.value(forHTTPHeaderField: "MCP-Session-Id"),
            protocolVersion: request.value(forHTTPHeaderField: "MCP-Protocol-Version"),
            method: body?["method"] as? String))
        let url = try #require(request.url)
        let httpResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers))
        return (Data(response.body.utf8), httpResponse)
    }

    func recordedRequests() -> [Request] {
        self.requests
    }
}
