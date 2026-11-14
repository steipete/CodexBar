import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct ElevenLabsSetupTests {
    @Test
    func `inventory declares the existing ElevenLabs API key route`() throws {
        let result = try Self.inventory(CodexBarConfig(providers: []))
        let encoded = try JSONEncoder().encode(result)
        let row = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let setup = try #require(row["setup"] as? [String: Any])
        #expect(setup["status"] as? String == "declared")
        #expect((setup["optionalCapabilities"] as? [Any])?.isEmpty == true)
        let routes = try #require(setup["routes"] as? [[String: Any]])
        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route["method"] as? String == "apiKey")
        #expect(route["platforms"] as? [String] == ["macOS", "linux"])
        #expect(route["command"] as? String == "codexbar config set-api-key --provider elevenlabs --stdin")
        let inputs = try #require(route["requiredInputs"] as? [[String: Any]])
        #expect(inputs.count == 1)
        #expect(inputs.first?["configFields"] as? [String] == ["apiKey", "tokenAccounts.accounts[].token"])
        #expect(inputs.first?["environmentVariables"] as? [String] == ["ELEVENLABS_API_KEY", "XI_API_KEY"])
        let hint = try #require(route["hint"] as? String)
        #expect(hint.contains("user_read"))
        #expect(hint.contains("standalone key"))
        #expect(hint.contains("selected API key account takes priority"))
    }

    @Test
    func `inventory stays static and omits saved credential values`() throws {
        let baseline = try Self.inventory(CodexBarConfig(providers: []))
        for entry in [
            ProviderConfig(id: .elevenlabs, enabled: false),
            ProviderConfig(id: .elevenlabs, enabled: true, apiKey: "setup-secret-canary-standalone"),
            ProviderConfig(id: .elevenlabs, enabled: true, tokenAccounts: Self.accounts()),
        ] {
            let result = try Self.inventory(CodexBarConfig(providers: [entry]))
            #expect(result.enabled == entry.enabled)
            #expect(result.setup == baseline.setup)
            #expect(result.authentication == baseline.authentication)
            let text = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
            #expect(!text.contains("setup-secret-canary"))
        }
    }

    @Test
    func `bundled specs and unavailable plugins retain unknown setup by default`() throws {
        #expect(DeepgramProviderDescriptor.spec.setup == .unknown)
        #expect(DeepgramProviderDescriptor.descriptor.setup == .unknown)
        let config = try CodexBarConfig.decode(from: Data(#"""
        {"version":1,"providers":[{"id":"elevenlabs-setup-unavailable",
        "pluginSecrets":{"TOKEN":"setup-secret-canary-plugin"}}]}
        """#.utf8))
        let result = try #require(CodexBarCLI.configProviderStatuses(config).first)
        #expect(result.provider == "elevenlabs-setup-unavailable")
        #expect(result.setup == .unknown)
        #expect(result.authentication == nil)
        let text = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        #expect(!text.contains("setup-secret-canary"))
    }

    @Test
    func `spec setup passes through inventory without evaluating credential callbacks`() throws {
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
        let descriptor = ElevenLabsProviderDescriptor.spec.makeDescriptor(
            credentials: credentials,
            fetchPlan: ProviderFetchPlan(sourceModes: [.api], pipeline: ProviderFetchPipeline(
                resolveStrategies: { _ in
                    Issue.record("Inventory must not select a fetch strategy")
                    return []
                })))
        let result = ConfigProviderStatusResult(
            config: ProviderConfig(id: .elevenlabs, apiKey: "setup-secret-canary-boundary"),
            descriptor: descriptor,
            displayName: "ElevenLabs")
        #expect(result.setup == ElevenLabsProviderDescriptor.spec.setup)
        #expect(result.setup.status == .declared)
        let text = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        #expect(!text.contains("setup-secret-canary"))
    }

    @Test
    func `advertised key inputs retain selected account config and environment precedence`() throws {
        let canonical = "ELEVENLABS_API_KEY"
        let alias = "XI_API_KEY"
        let ambient = [canonical: "setup-secret-canary-canonical", alias: "setup-secret-canary-alias"]
        let fixtures: [(values: [String: String], saved: String?, selected: Bool, expected: String?)] = [
            (ambient, "setup-secret-canary-config", true, "setup-secret-canary-account-b"),
            (ambient, " setup-secret-canary-config ", false, "setup-secret-canary-config"),
            (ambient, nil, false, "setup-secret-canary-canonical"),
            ([canonical: " \n ", alias: "setup-secret-canary-alias"], nil, false, "setup-secret-canary-alias"),
            ([alias: "setup-secret-canary-alias"], " \n ", false, "setup-secret-canary-alias"),
            ([:], nil, false, nil),
        ]
        for fixture in fixtures {
            let config = CodexBarConfig(providers: [ProviderConfig(
                id: .elevenlabs,
                apiKey: fixture.saved,
                tokenAccounts: fixture.selected ? Self.accounts() : nil)])
            let context = try Self.context(config)
            let selected = try context.resolvedAccounts(for: .elevenlabs).first
            let values = context.environment(base: fixture.values, provider: .elevenlabs, account: selected)
            #expect(ElevenLabsProviderDescriptor.spec.apiKey(environment: values) == fixture.expected)
            #expect(ElevenLabsSettingsReader.apiKey(environment: values) == fixture.expected)
        }
    }

    @Test
    func `storing a standalone key preserves the selected saved account`() throws {
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .elevenlabs,
            enabled: false,
            apiKey: "setup-secret-canary-old",
            tokenAccounts: Self.accounts())])
        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .elevenlabs,
            apiKey: "setup-secret-canary-new",
            enableProvider: true)
        let entry = try #require(updated.providerConfig(for: .elevenlabs))
        #expect(entry.apiKey == "setup-secret-canary-new")
        #expect(entry.enabled == true)
        #expect(entry.tokenAccounts?.activeIndex == 1)
        #expect(entry.tokenAccounts?.accounts.map(\.token) == Self.accounts().accounts.map(\.token))
        let context = try Self.context(updated)
        let selected = try context.resolvedAccounts(for: .elevenlabs).first
        #expect(selected?.id == Self.accounts().accounts[1].id)
        let values = context.environment(base: [:], provider: .elevenlabs, account: selected)
        #expect(ElevenLabsSettingsReader.apiKey(environment: values) == "setup-secret-canary-account-b")
    }

    private static func inventory(_ config: CodexBarConfig) throws -> ConfigProviderStatusResult {
        try #require(CodexBarCLI.configProviderStatuses(config).first { $0.provider == "elevenlabs" })
    }

    private static func context(_ config: CodexBarConfig) throws -> TokenAccountCLIContext {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            configStore: CodexBarConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("elevenlabs-setup-\(UUID())/config.json")))
    }

    private static func accounts() -> ProviderTokenAccountData {
        ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                    label: "Fixture A",
                    token: "setup-secret-canary-account-a",
                    addedAt: 0,
                    lastUsed: nil),
                ProviderTokenAccount(
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    label: "Fixture B",
                    token: "setup-secret-canary-account-b",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 1)
    }
}
