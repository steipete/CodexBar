import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct RefuselessPluginTests {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    static let response = #"""
    {"object":"credits","balance":42.5,"reserved":1.2,"available":10.9,
     "key_limit":10.9,"unit":"usd","updated_at":1793836800}
    """#

    @Test
    func `installed sample waits for approval and makes one authenticated GET`() async throws {
        let harness = try Self.makeHarness(body: Self.response)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let plugin = harness.plugin
        let binding = try plugin.approvalBinding(settings: [:])
        #expect(plugin.manifest.id.rawValue == "refuseless")
        #expect(binding.origins == ["https://api.refuseless.com"])
        #expect(binding.authMode == "bearer")
        #expect(binding.secretNames == ["REFUSELESS_API_KEY"])
        #expect(binding.capabilities == ["http-status"])

        await #expect {
            try await plugin.fetchUsage(
                settings: [:],
                secrets: ["REFUSELESS_API_KEY": "fixture-key"],
                environment: [:],
                approvalStore: harness.approvals,
                sourceMode: .api)
        } throws: { error in
            guard let error = error as? UserProviderPluginError else { return false }
            return error == .approvalRequired(binding)
        }
        #expect(await harness.requests.captured.isEmpty)

        try harness.approvals.record(binding)
        let usage = try await plugin.fetchUsage(
            settings: [:],
            secrets: ["REFUSELESS_API_KEY": "fixture-key"],
            environment: [:],
            approvalStore: harness.approvals,
            sourceMode: .api)

        let captured = await harness.requests.captured
        #expect(captured.count == 1)
        #expect(captured.first?.url == "https://api.refuseless.com/v1/credits")
        #expect(captured.first?.method == "GET")
        #expect(captured.first?.authorization == "Bearer fixture-key")
        #expect(captured.first?.hasBody == false)

        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.dataConfidence == .exact)
        #expect(usage.details.first?.title == "Credits")
        #expect(usage.details.first?.rows.map(\.label) == [
            "Available", "Balance", "Reserved", "Budget remaining", "Updated",
        ])
        #expect(Self.row("Available", in: usage) == "$10.90")
        #expect(Self.row("Balance", in: usage) == "$42.50")
        #expect(Self.row("Reserved", in: usage) == "$1.20")
        #expect(Self.row("Budget remaining", in: usage) == "$10.90")
        #expect(Self.row("Updated", in: usage) == "2026-11-05T00:00:00.000Z")
    }

    @Test(arguments: Self.engines)
    func `null and zero budgets stay distinct and six decimal USD remains visible`(
        engine: ProviderPluginEngineKind) async throws
    {
        let noBudgetBody = #"""
        {"object":"credits","balance":1,"reserved":0,"available":1,"key_limit":null,
         "unit":"usd","updated_at":1793836800}
        """#
        let noBudget = try await Self.fetch(engine: engine, body: noBudgetBody)
        #expect(Self.row("Budget remaining", in: noBudget) == "No key budget")

        let zeroBudgetBody = #"""
        {"object":"credits","balance":0,"reserved":0,"available":0,"key_limit":0,
         "unit":"usd","updated_at":1793836800}
        """#
        let zeroBudget = try await Self.fetch(engine: engine, body: zeroBudgetBody)
        #expect(Self.row("Budget remaining", in: zeroBudget) == "$0.00")

        let microBalanceBody = #"""
        {"object":"credits","balance":0.000001,"reserved":0,"available":0.000001,
         "key_limit":0.000001,"unit":"usd","updated_at":1793836800}
        """#
        let microBalance = try await Self.fetch(engine: engine, body: microBalanceBody)
        #expect(Self.row("Available", in: microBalance) == "$0.000001")
        #expect(Self.row("Balance", in: microBalance) == "$0.000001")
    }

    @Test(arguments: Self.engines)
    func `malformed or undocumented response fields fail closed`(engine: ProviderPluginEngineKind) async {
        let malformed = [
            "not-json",
            "[]",
            "{}",
            Self.response.replacingOccurrences(
                of: #""object":"credits""#,
                with: #""object":"balance""#),
            Self.response.replacingOccurrences(
                of: #""unit":"usd""#,
                with: #""unit":"credits""#),
            Self.response.replacingOccurrences(
                of: #""balance":42.5"#,
                with: #""balance":"42.5""#),
            Self.response.replacingOccurrences(
                of: #""reserved":1.2"#,
                with: #""reserved":true"#),
            Self.response.replacingOccurrences(
                of: #""available":10.9"#,
                with: #""available":1e999"#),
            Self.response.replacingOccurrences(
                of: #""key_limit":10.9"#,
                with: #""key_limit":"10.9""#),
            Self.response.replacingOccurrences(
                of: #""updated_at":1793836800"#,
                with: #""updated_at":1793836800.5"#),
        ]

        for body in malformed {
            do {
                let harness = try Self.makeHarness(engine: engine, body: body)
                defer { try? FileManager.default.removeItem(at: harness.root) }
                try harness.approvals.record(harness.plugin.approvalBinding(settings: [:]))
                await #expect {
                    try await harness.plugin.fetchUsage(
                        settings: [:],
                        secrets: ["REFUSELESS_API_KEY": "fixture-key"],
                        environment: [:],
                        approvalStore: harness.approvals,
                        sourceMode: .api)
                } throws: { error in
                    guard let classified = error as? ProviderFetchClassifiedError else { return false }
                    return classified.kind == .parseFailure &&
                        classified.localizedDescription.contains("Update the plugin") &&
                        classified.localizedDescription.contains("contact Refuseless support")
                }
            } catch {
                Issue.record("Could not load Refuseless fixture: \(error)")
            }
        }
    }

    @Test(arguments: Self.engines)
    func `HTTP statuses are classified without exposing response bodies`(engine: ProviderPluginEngineKind) async {
        let cases: [(Int, ProviderFetchClassifiedError.Kind)] = [
            (401, .authenticationExpired),
            (403, .apiFailure),
            (429, .rateLimited),
            (500, .providerUnavailable),
            (503, .providerUnavailable),
            (404, .apiFailure),
        ]
        for (status, expected) in cases {
            do {
                let harness = try Self.makeHarness(engine: engine, body: "private-response-marker", status: status)
                defer { try? FileManager.default.removeItem(at: harness.root) }
                try harness.approvals.record(harness.plugin.approvalBinding(settings: [:]))
                await #expect {
                    try await harness.plugin.fetchUsage(
                        settings: [:],
                        secrets: ["REFUSELESS_API_KEY": "fixture-key"],
                        environment: [:],
                        approvalStore: harness.approvals,
                        sourceMode: .api)
                } throws: { error in
                    guard let classified = error as? ProviderFetchClassifiedError else { return false }
                    let description = classified.localizedDescription
                    return classified.kind == expected && !description.contains("private-response-marker") &&
                        (expected != .apiFailure || description.contains("contact Refuseless support"))
                }
            } catch {
                Issue.record("Could not load Refuseless fixture: \(error)")
            }
        }
    }

    private static func fetch(engine: ProviderPluginEngineKind, body: String) async throws -> UsageSnapshot {
        let harness = try Self.makeHarness(engine: engine, body: body)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try harness.approvals.record(harness.plugin.approvalBinding(settings: [:]))
        return try await harness.plugin.fetchUsage(
            settings: [:],
            secrets: ["REFUSELESS_API_KEY": "fixture-key"],
            environment: [:],
            approvalStore: harness.approvals,
            sourceMode: .api)
    }

    private static func makeHarness(
        engine: ProviderPluginEngineKind? = nil,
        body: String,
        status: Int = 200) throws -> Harness
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-refuseless-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let requests = RequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await requests.capture(
                url: request.url?.absoluteString,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                hasBody: request.httpBody != nil)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
        let plugin: UserProviderPlugin
        if let engine {
            let source = try String(contentsOf: Self.exampleURL, encoding: .utf8)
            let runtime = try ProviderPluginRuntime(
                source: source,
                transport: transport,
                responseSizeLimit: UserProviderPlugin.maximumSourceBytes,
                enforcesUserResponsePolicy: true,
                allowsDynamicID: true,
                engine: engine)
            plugin = UserProviderPlugin(
                fileURL: Self.exampleURL,
                sourceHash: "fixture",
                transpiledCacheURL: nil,
                transpileCacheHit: false,
                runtime: runtime)
        } else {
            let loader = UserProviderPluginLoader(
                providersDirectory: providers,
                cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
                transport: transport)
            plugin = try loader.install(fileURL: Self.exampleURL)
        }
        return Harness(
            root: root,
            plugin: plugin,
            approvals: ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json")),
            requests: requests)
    }

    private static var exampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Examples/Plugins/refuseless.js")
            .standardizedFileURL
    }

    private static func row(_ label: String, in usage: UsageSnapshot) -> String? {
        usage.details.flatMap(\.rows).first { $0.label == label }?.value
    }

    private struct Harness {
        let root: URL
        let plugin: UserProviderPlugin
        let approvals: ProviderPluginApprovalStore
        let requests: RequestRecorder
    }

    private struct CapturedRequest: Equatable, Sendable {
        let url: String?
        let method: String?
        let authorization: String?
        let hasBody: Bool
    }

    private actor RequestRecorder {
        private var items: [CapturedRequest] = []

        var captured: [CapturedRequest] {
            self.items
        }

        func capture(url: String?, method: String?, authorization: String?, hasBody: Bool) {
            self.items.append(CapturedRequest(url: url, method: method, authorization: authorization, hasBody: hasBody))
        }
    }
}
