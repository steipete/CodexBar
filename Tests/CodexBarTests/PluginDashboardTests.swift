import Foundation
import Testing
@testable import CodexBarCore

struct PluginDashboardTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `separate HTTPS dashboard is bound without adding network authority`(engine: ProviderPluginEngineKind) throws {
        let manifest = try self.manifest(field: Self.literal("https://dashboard.example.test/usage"), engine: engine)
        let binding = try ProviderPluginApprovalBinding(manifest: manifest, settings: [:])
        #expect(binding.dashboardURL == "https://dashboard.example.test/usage")
        #expect(binding.origins == ["https://api.example.test"])
        #expect(binding.typedConfirmationOrigins.isEmpty)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        legacy.removeValue(forKey: "dashboardURL")
        let restored = try JSONDecoder().decode(
            ProviderPluginApprovalBinding.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.dashboardURL == nil)
        #expect(restored != binding)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plain setting dashboards reuse approved loopback origins`(engine: ProviderPluginEngineKind) throws {
        let manifest = try self.manifest(
            field: #"{setting: "BASE_URL"}"#,
            settings: #"[{key: "BASE_URL", title: "Endpoint", type: "plain"}]"#,
            endpoints: #"[{setting: "BASE_URL", policy: "https-or-loopback-http"}]"#,
            engine: engine)
        let url = "http://127.0.0.1:4318/dashboard"
        let binding = try ProviderPluginApprovalBinding(manifest: manifest, settings: ["BASE_URL": url])
        #expect(binding.dashboardURL == url)
        #expect(binding.typedConfirmationOrigins == ["http://127.0.0.1:4318"])
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "https://user:pass@example.test/",
        "https://example.test/#fragment",
        "http://example.test/",
    ])
    func `unsafe dashboard destinations are rejected`(url: String) throws {
        #expect(throws: ProviderPluginError.self) { try self.manifest(field: Self.literal(url)) }
    }

    @Test
    func `loopback dashboards need an approved endpoint and settings must be plain`() throws {
        let loopback = try self.manifest(field: Self.literal("http://127.0.0.1:4318/dashboard"))
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginApprovalBinding(manifest: loopback, settings: [:])
        }
        #expect(throws: ProviderPluginError.self) {
            try self.manifest(
                field: #"{setting: "TOKEN"}"#,
                settings: #"[{key: "TOKEN", title: "Token", type: "secure"}]"#)
        }
    }

    @Test(arguments: [nil, "null", "undefined", "\"\""] as [String?])
    func `omitted and empty dashboard links stay absent`(field: String?) throws {
        let binding = try ProviderPluginApprovalBinding(manifest: self.manifest(field: field), settings: [:])
        #expect(binding.dashboardURL == nil)
    }

    @Test
    func `setting changes require approval and unresolved settings expose no action`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dashboard.js")
        try Data(Self.source(
            field: #"{setting: "DASHBOARD"}"#,
            settings: #"[{key: "DASHBOARD", title: "Dashboard", type: "plain"}]"#,
            id: "dashboard-fixture").utf8).write(to: url)
        let plugin = try UserProviderPluginLoader(
            providersDirectory: root, cacheDirectory: root.appendingPathComponent("cache")).load(fileURL: url)
        let approvals = ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let first = ["DASHBOARD": "https://api.example.test/first"]
        #expect(plugin.approvedDashboardURL(settings: first, approvalStore: approvals) == nil)
        try approvals.record(plugin.approvalBinding(settings: first))
        #expect(plugin.approvedDashboardURL(settings: first, approvalStore: approvals)?.path == "/first")
        #expect(plugin.approvedDashboardURL(
            settings: ["DASHBOARD": "https://api.example.test/second"],
            approvalStore: approvals) == nil)
        #expect(plugin.approvedDashboardURL(settings: [:], approvalStore: approvals) == nil)
        #expect(throws: ProviderPluginError.self) {
            try plugin.approvalBinding(settings: ["DASHBOARD": "https://unapproved.example.test/"])
        }
    }

    private func manifest(
        field: String?,
        settings: String = "[]",
        endpoints: String = #"["https://api.example.test"]"#,
        engine: ProviderPluginEngineKind = .quickJS) throws -> ProviderPluginManifest
    {
        try ProviderPluginRuntime(
            source: Self.source(field: field, settings: settings, endpoints: endpoints),
            engine: engine).manifest
    }

    private static func literal(_ value: String) throws -> String {
        try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
    }

    private static func source(
        field: String?,
        settings: String = "[]",
        endpoints: String = #"["https://api.example.test"]"#,
        id: String = "synthetic") -> String
    {
        """
        defineProvider({id: "\(id)", name: "Fixture", endpoints: \(endpoints), settings: \(settings),
          \(field.map { "dashboardURL: \($0)," } ?? "")
          fetchUsage() { return {primary: {usedPercent: 1}}; }});
        """
    }
}
