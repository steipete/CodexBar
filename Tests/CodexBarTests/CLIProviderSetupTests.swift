import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderSetupTests {
    @Test
    func `Copilot offers device login or a token without requiring budget cookies`() throws {
        let setup = try Self.setup("copilot")
        #expect(setup["status"] as? String == "declared")
        let routes = try #require(setup["routes"] as? [[String: Any]])
        #expect(routes.compactMap { $0["id"] as? String } == ["device-login", "github-token"])
        let device = try #require(routes.first)
        #expect(device["method"] as? String == "deviceCode")
        #expect(device["command"] as? String == "codexbar config login --provider copilot")
        #expect(device["platforms"] as? [String] == ["macOS", "linux"])
        #expect((device["requiredInputs"] as? [[String: Any]])?.isEmpty == true)
        let token = try #require(routes.last)
        #expect(token["method"] as? String == "token")
        let inputs = try #require(token["requiredInputs"] as? [[String: Any]])
        #expect(inputs.compactMap { $0["id"] as? String } == ["github-token"])
        #expect(inputs.first?["configFields"] as? [String] == ["apiKey", "tokenAccounts.accounts[].token"])
        #expect(inputs.first?["environmentVariables"] as? [String] == ["COPILOT_API_TOKEN"])
    }

    @Test
    func `Copilot budget cookies are optional and require macOS app setup`() throws {
        let setup = try Self.setup("copilot")
        let capabilities = try #require(setup["optionalCapabilities"] as? [[String: Any]])
        #expect(capabilities.compactMap { $0["id"] as? String } == ["budget-extras"])
        let routes = try #require(capabilities.first?["routes"] as? [[String: Any]])
        #expect(routes.compactMap { $0["id"] as? String } == ["manual-cookie", "browser-session"])
        let manual = try #require(routes.first)
        #expect(manual["method"] as? String == "cookieHeader")
        #expect(manual["platforms"] as? [String] == ["macOS"])
        let inputs = try #require(manual["requiredInputs"] as? [[String: Any]])
        #expect(inputs.first?["configFields"] as? [String] == ["cookieHeader"])
        #expect(inputs.first?["environmentVariables"] as? [String] == [])
        let browser = try #require(routes.last)
        #expect(browser["method"] as? String == "browserSession")
        #expect(browser["platforms"] as? [String] == ["macOS"])
    }

    @Test
    func `manual cookies cannot advertise Linux budgets without CLI settings support`() throws {
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .copilot,
            extrasEnabled: true,
            apiKey: "synthetic-copilot-token",
            cookieHeader: "user_session=synthetic-copilot-cookie",
            cookieSource: .manual)])
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-fixture-\(UUID())/config.json")
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            configStore: CodexBarConfigStore(fileURL: storeURL))
        let settings = context.settingsSnapshot(for: .copilot, account: nil)?.copilot
        let setup = try Self.setup("copilot")
        let capabilities = try #require(setup["optionalCapabilities"] as? [[String: Any]])
        let routes = try #require(capabilities.first?["routes"] as? [[String: Any]])
        let advertisesLinux = routes.contains { ($0["platforms"] as? [String])?.contains("linux") == true }
        #expect(!advertisesLinux || settings?.budgetExtrasEnabled == true)
    }

    @Test
    func `OpenAI offers Admin key access and a macOS browser session`() throws {
        let setup = try Self.setup("openai")
        let routes = try #require(setup["routes"] as? [[String: Any]])
        #expect(routes.compactMap { $0["id"] as? String } == ["admin-api-key", "browser-session"])
        let admin = try #require(routes.first)
        #expect(admin["method"] as? String == "apiKey")
        #expect(admin["platforms"] as? [String] == ["macOS", "linux"])
        let adminInputs = try #require(admin["requiredInputs"] as? [[String: Any]])
        #expect(adminInputs.compactMap { $0["id"] as? String } == ["admin-api-key"])
        #expect(adminInputs.first?["configFields"] as? [String] == ["apiKey", "tokenAccounts.accounts[].token"])
        #expect(adminInputs.first?["environmentVariables"] as? [String] == ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"])
        let browser = try #require(routes.last)
        #expect(browser["method"] as? String == "browserSession")
        #expect(browser["platforms"] as? [String] == ["macOS"])
    }

    @Test
    func `Azure requires a key endpoint and deployment but not an explicit API version`() throws {
        let setup = try Self.setup("azureopenai")
        let routes = try #require(setup["routes"] as? [[String: Any]])
        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route["method"] as? String == "apiKey")
        #expect(route["platforms"] as? [String] == ["macOS", "linux"])
        let inputs = try #require(route["requiredInputs"] as? [[String: Any]])
        #expect(inputs.compactMap { $0["id"] as? String } == ["api-key", "endpoint", "deployment"])
        #expect(inputs.compactMap { $0["configFields"] as? [String] } == [
            ["apiKey"], ["enterpriseHost"], ["workspaceID"],
        ])
        #expect(inputs.compactMap { $0["environmentVariables"] as? [String] } == [
            ["AZURE_OPENAI_API_KEY"], ["AZURE_OPENAI_ENDPOINT"], ["AZURE_OPENAI_DEPLOYMENT_NAME"],
        ])
    }

    @Test
    func `undeclared setup remains unknown even when authentication inputs are supported`() throws {
        let rows = try Self.rows(CodexBarConfig(providers: [ProviderConfig(id: .groq)]))
        let row = try #require(rows.first { $0["provider"] as? String == "groq" })
        let authentication = try #require(row["authentication"] as? [String: Any])
        #expect(authentication["supportsConfigAPIKey"] as? Bool == true)
        let setup = try #require(row["setup"] as? [String: Any])
        #expect(setup["status"] as? String == "unknown")
        #expect((setup["routes"] as? [[String: Any]])?.isEmpty == true)
        #expect((setup["optionalCapabilities"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test
    func `unavailable plugin setup is explicit and inventory never serializes its secrets`() throws {
        let config = try CodexBarConfig.decode(from: Data(#"""
        {"version":1,"providers":[
          {"id":"fixture-setup-unavailable","enabled":true,"pluginSecrets":{"TOKEN":"synthetic-plugin-secret"}}
        ]}
        """#.utf8))
        let rows = try Self.rows(config)
        let row = try #require(rows.first)
        #expect(row["provider"] as? String == "fixture-setup-unavailable")
        #expect(row["displayName"] as? String == "plugin (not loaded)")
        #expect(row["enabled"] as? Bool == true)
        #expect(row["defaultEnabled"] as? Bool == false)
        #expect(row["authentication"] == nil)
        let setup = try #require(row["setup"] as? [String: Any])
        #expect(setup["status"] as? String == "unknown")
        #expect((setup["routes"] as? [[String: Any]])?.isEmpty == true)
        #expect((setup["optionalCapabilities"] as? [[String: Any]])?.isEmpty == true)
        let json = try JSONEncoder().encode(CodexBarCLI.configProviderStatuses(config))
        let text = try #require(String(data: json, encoding: .utf8))
        #expect(!text.contains("synthetic-plugin-secret"))
    }

    @Test(arguments: [UsageProvider.copilot, .openai, .azureopenai])
    func `setup stays static across enablement and synthetic credentials`(_ provider: UsageProvider) throws {
        let empty = try Self.rows(CodexBarConfig(providers: [ProviderConfig(id: provider.instanceID, enabled: false)]))
        let configured = try Self.rows(CodexBarConfig(providers: [ProviderConfig(
            id: provider.instanceID,
            enabled: true,
            apiKey: "synthetic-setup-key",
            cookieHeader: "synthetic-setup-cookie",
            workspaceID: "synthetic-setup-deployment",
            enterpriseHost: "https://synthetic-setup.example")]))
        let before = try #require(empty.first { $0["provider"] as? String == provider.rawValue })
        let after = try #require(configured.first { $0["provider"] as? String == provider.rawValue })
        #expect(before["enabled"] as? Bool == false)
        #expect(after["enabled"] as? Bool == true)
        #expect(after["defaultEnabled"] as? Bool == false)
        let beforeSetup = try #require(before["setup"] as? NSDictionary)
        let afterSetup = try #require(after["setup"] as? NSDictionary)
        #expect(beforeSetup == afterSetup)
        let beforeAuthentication = try #require(before["authentication"] as? NSDictionary)
        let afterAuthentication = try #require(after["authentication"] as? NSDictionary)
        #expect(beforeAuthentication == afterAuthentication)
        let data = try JSONSerialization.data(withJSONObject: configured)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("synthetic-setup-"))
    }

    @Test
    func `inventory row uses provider declarations without invoking credential callbacks`() throws {
        let base = OpenAIAPIProviderDescriptor.descriptor
        let credentials = ProviderCredentialAdapter(
            supportsAPIKeyOverride: true,
            environmentProjections: [.init(key: "FIXTURE_KEY", value: { _ in
                Issue.record("Inventory must not project credential values")
                return nil
            })],
            tokenResolver: { _, _, _ in
                Issue.record("Inventory must not resolve credentials")
                return nil
            },
            authDetector: { _, _ in
                Issue.record("Inventory must not detect authentication")
                return []
            },
            diagnosticSummary: { _, _, _, _ in
                Issue.record("Inventory must not diagnose credentials")
                return ProviderDiagnosticAuthSummary(configured: false, modes: [])
            })
        let descriptor = ProviderDescriptor(
            id: .openai,
            credentials: credentials,
            metadata: base.metadata,
            branding: base.branding,
            tokenCost: base.tokenCost,
            fetchPlan: ProviderFetchPlan(sourceModes: [.api], pipeline: ProviderFetchPipeline(
                resolveStrategies: { _ in
                    Issue.record("Inventory must not select a fetch strategy")
                    return []
                })),
            cli: base.cli,
            setup: ProviderSetup(routes: [.init(
                id: "fixture-route",
                method: .apiKey,
                platforms: [.linux],
                requiredInputs: [.init(id: "key", environmentVariables: ["FIXTURE_KEY"])],
                hint: "Fixture declaration")]))
        let result = ConfigProviderStatusResult(
            config: ProviderConfig(id: .openai, apiKey: "synthetic-boundary-secret"),
            descriptor: descriptor,
            displayName: "Fixture")
        let data = try JSONEncoder().encode(result)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setup = try #require(row["setup"] as? [String: Any])
        let routes = try #require(setup["routes"] as? [[String: Any]])
        #expect(routes.first?["id"] as? String == "fixture-route")
        #expect(routes.first?["platforms"] as? [String] == ["linux"])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("synthetic-boundary-secret"))
    }

    private static func setup(_ provider: String) throws -> [String: Any] {
        let rows = try Self.rows(.makeDefault())
        let row = try #require(rows.first { $0["provider"] as? String == provider })
        return try #require(row["setup"] as? [String: Any])
    }

    private static func rows(_ config: CodexBarConfig) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(CodexBarCLI.configProviderStatuses(config))
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
