import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct DeepInfraSetupTests {
    private static let hint = "The command reads a piped API key and saves it as a standalone key. " +
        "A selected API token account overrides the standalone key."

    @Test
    func `inventory declares the existing DeepInfra API key route`() throws {
        let row = try Self.row(CodexBarConfig(providers: []))
        let expected: [String: Any] = [
            "status": "declared",
            "routes": [[
                "id": "api-key",
                "method": "apiKey",
                "platforms": ["macOS", "linux"],
                "requiredInputs": [[
                    "id": "api-key",
                    "configFields": ["apiKey", "tokenAccounts.accounts[].token"],
                    "environmentVariables": ["DEEPINFRA_API_KEY", "DEEPINFRA_TOKEN"],
                ]],
                "command": "codexbar config set-api-key --provider deepinfra --stdin",
                "hint": UsageFormatter.localized(Self.hint),
            ]],
            "optionalCapabilities": [],
        ]
        #expect(try #require(row["setup"] as? NSDictionary) == expected as NSDictionary)
    }

    @Test
    func `authentication metadata retains the existing contract`() throws {
        let row = try Self.row(CodexBarConfig(providers: []))
        let expected: [String: Any] = [
            "sourceModes": ["api", "auto"],
            "supportsConfigAPIKey": true,
            "supportsConfigCookieHeader": false,
            "environmentVariables": ["DEEPINFRA_API_KEY"],
            "tokenAccounts": ["title": "API tokens", "setupHint": "Store multiple DeepInfra API keys."],
        ]
        #expect(try #require(row["authentication"] as? NSDictionary) == expected as NSDictionary)
    }

    @Test
    func `inventory stays static and omits credentials across providers`() throws {
        let baseline = try Self.inventory(CodexBarConfig(providers: []))
        for entry in [
            ProviderConfig(id: .deepinfra, enabled: false),
            ProviderConfig(id: .deepinfra, enabled: true, apiKey: "deepinfra-secret-canary-config"),
            ProviderConfig(id: .deepinfra, enabled: true, tokenAccounts: Self.accounts()),
        ] {
            let config = CodexBarConfig(providers: [entry, Self.otherProvider()])
            let result = try Self.inventory(config)
            #expect(result.enabled == entry.enabled)
            #expect(result.setup == baseline.setup)
            #expect(result.authentication == baseline.authentication)
            let text = try #require(String(
                data: JSONEncoder().encode(CodexBarCLI.configProviderStatuses(config)), encoding: .utf8))
            #expect(!text.contains("deepinfra-secret-canary"))
        }
    }

    @Test
    func `inventory passes through the declaration without evaluating credentials`() throws {
        let credentials = ProviderCredentialAdapter(
            supportsAPIKeyOverride: true,
            environmentProjections: [.init(key: "DEEPINFRA_API_KEY", value: { _ in
                Issue.record("Inventory must not project credentials")
                return nil
            })],
            environmentOverride: { _, _ in
                Issue.record("Inventory must not apply credential overrides")
                return [:]
            },
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
        let descriptor = DeepInfraProviderDescriptor.spec.makeDescriptor(
            credentials: credentials,
            fetchPlan: ProviderFetchPlan(sourceModes: [.api], pipeline: ProviderFetchPipeline(
                resolveStrategies: { _ in
                    Issue.record("Inventory must not select a fetch strategy")
                    return []
                })))
        let result = ConfigProviderStatusResult(
            config: ProviderConfig(id: .deepinfra, apiKey: "deepinfra-secret-canary-boundary"),
            descriptor: descriptor,
            displayName: "DeepInfra")
        #expect(result.setup == DeepInfraProviderDescriptor.spec.setup)
        #expect(result.setup.status == .declared)
        let text = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        #expect(!text.contains("deepinfra-secret-canary"))
    }

    @Test
    func `advertised command resolves to the existing stdin setter`() throws {
        let route = try #require(DeepInfraProviderDescriptor.descriptor.setup.routes.first)
        let command = try #require(route.command)
        let arguments = command.split(separator: " ").map(String.init)
        #expect(arguments.first == "codexbar")
        let program = Program(descriptors: CodexBarCLI.commandDescriptors(for: "config"))
        let invocation = try program.resolve(arguments: Array(arguments.dropFirst()))
        #expect(invocation.path == ["config", "set-api-key"])
        #expect(invocation.parsedValues.options["provider"] == ["deepinfra"])
        #expect(invocation.parsedValues.flags.contains("stdin"))
        #expect(invocation.parsedValues.options["apiKey"] == nil)
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .deepinfra))
    }

    @Test
    func `usable keys retain selected account config and environment precedence`() throws {
        let canonical = "DEEPINFRA_API_KEY"
        let alias = "DEEPINFRA_TOKEN"
        let ambient = [canonical: "deepinfra-secret-canary-canonical", alias: "deepinfra-secret-canary-alias"]
        let fixtures: [(values: [String: String], saved: String?, selected: String?, expected: String?)] = [
            (ambient, "deepinfra-secret-canary-config", "deepinfra-secret-canary-b", "deepinfra-secret-canary-b"),
            (ambient, "deepinfra-secret-canary-config", " 'deepinfra-secret-canary-b' ", "deepinfra-secret-canary-b"),
            (ambient, " 'deepinfra-secret-canary-config' ", nil, "deepinfra-secret-canary-config"),
            (ambient, "\"\"", nil, "deepinfra-secret-canary-canonical"),
            (ambient, nil, nil, "deepinfra-secret-canary-canonical"),
            ([canonical: " \n ", alias: "deepinfra-secret-canary-alias"], nil, nil, "deepinfra-secret-canary-alias"),
            ([alias: "deepinfra-secret-canary-alias"], " \n ", nil, "deepinfra-secret-canary-alias"),
            ([:], nil, nil, nil),
        ]
        for fixture in fixtures {
            let entry = ProviderConfig(
                id: .deepinfra,
                apiKey: fixture.saved,
                tokenAccounts: fixture.selected.map { Self.accounts(selectedToken: $0) })
            let context = try Self.context(CodexBarConfig(providers: [entry, Self.otherProvider()]))
            let selected = try context.resolvedAccounts(for: .deepinfra).first
            #expect(selected?.id == fixture.selected.map { _ in Self.accounts().accounts[1].id })
            let values = context.environment(base: fixture.values, provider: .deepinfra, account: selected)
            #expect(DeepInfraProviderDescriptor.spec.apiKey(environment: values) == fixture.expected)
            #expect(DeepInfraSettingsReader.apiKey(environment: values) == fixture.expected)
        }
    }

    @Test(arguments: ["", " \n ", "\"\"", "'  '"])
    func `blank selected tokens preserve the existing alias fallback`(token: String) throws {
        let entry = ProviderConfig(
            id: .deepinfra,
            apiKey: "deepinfra-secret-canary-config",
            tokenAccounts: Self.accounts(selectedToken: token))
        let context = try Self.context(CodexBarConfig(providers: [entry, Self.otherProvider()]))
        let selected = try #require(context.resolvedAccounts(for: .deepinfra).first)
        #expect(selected.id == Self.accounts().accounts[1].id)
        for alias in ["deepinfra-secret-canary-alias", " \n ", ""] {
            let values = context.environment(
                base: ["DEEPINFRA_API_KEY": "deepinfra-secret-canary-canonical", "DEEPINFRA_TOKEN": alias],
                provider: .deepinfra,
                account: selected)
            let expected: String? = alias == "deepinfra-secret-canary-alias" ? alias : nil
            #expect(values["DEEPINFRA_API_KEY"] == token)
            #expect(DeepInfraSettingsReader.apiKey(environment: values) == expected)
        }
        let values = context.environment(
            base: ["DEEPINFRA_API_KEY": "deepinfra-secret-canary-canonical"], provider: .deepinfra, account: selected)
        #expect(DeepInfraSettingsReader.apiKey(environment: values) == nil)
    }

    @Test(arguments: [false, true])
    func `storing a standalone key preserves selected accounts and source`(enable: Bool) throws {
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .deepinfra,
            enabled: false,
            source: .api,
            apiKey: "deepinfra-secret-canary-old",
            tokenAccounts: Self.accounts()), Self.otherProvider()])
        let updated = CodexBarCLI.configSettingAPIKey(
            config, provider: .deepinfra, apiKey: "deepinfra-secret-canary-new", enableProvider: enable)
        let entry = try #require(updated.providerConfig(for: .deepinfra))
        #expect(entry.apiKey == "deepinfra-secret-canary-new")
        #expect(entry.enabled == enable)
        #expect(entry.source == .api)
        #expect(entry.tokenAccounts?.activeIndex == 1)
        #expect(entry.tokenAccounts?.accounts.map(\.id) == Self.accounts().accounts.map(\.id))
        #expect(entry.tokenAccounts?.accounts.map(\.token) == Self.accounts().accounts.map(\.token))
        let context = try Self.context(updated)
        let selected = try context.resolvedAccounts(for: .deepinfra).first
        let values = context.environment(base: [:], provider: .deepinfra, account: selected)
        #expect(DeepInfraSettingsReader.apiKey(environment: values) == "deepinfra-secret-canary-b")
    }

    private static func inventory(_ config: CodexBarConfig) throws -> ConfigProviderStatusResult {
        try #require(CodexBarCLI.configProviderStatuses(config).first { $0.provider == "deepinfra" })
    }

    private static func row(_ config: CodexBarConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(Self.inventory(config))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func context(_ config: CodexBarConfig) throws -> TokenAccountCLIContext {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config.normalized(),
            verbose: false,
            baseEnvironment: [:],
            configStore: CodexBarConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("deepinfra-setup-\(UUID())/config.json")))
    }

    private static func accounts(selectedToken: String = "deepinfra-secret-canary-b") -> ProviderTokenAccountData {
        ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                    label: "Fixture A",
                    token: "deepinfra-secret-canary-a",
                    addedAt: 0,
                    lastUsed: nil),
                ProviderTokenAccount(
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    label: "Fixture B",
                    token: selectedToken,
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 1)
    }

    private static func otherProvider() -> ProviderConfig {
        ProviderConfig(
            id: .elevenlabs,
            enabled: false,
            apiKey: "deepinfra-secret-canary-other-config",
            tokenAccounts: ProviderTokenAccountData(
                version: 1,
                accounts: [ProviderTokenAccount(
                    id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                    label: "Other provider",
                    token: "deepinfra-secret-canary-other-account",
                    addedAt: 0,
                    lastUsed: nil)],
                activeIndex: 0))
    }
}
