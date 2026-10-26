import CodexBarCore
import Commander
import Foundation

enum ConfigCredentialField: String, CaseIterable, Encodable {
    case apiKey
    case cookieHeader
}

extension CodexBarCLI {
    static func runConfigClearCredential(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        guard let rawProvider = values.options["provider"]?.last,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            Self.exit(
                code: .failure,
                message: "Unknown or missing provider. Use --provider <name>.",
                output: output,
                kind: .args)
        }
        let fields = Self.configCredentialFields(
            apiKey: values.flags.contains("apiKey"),
            cookie: values.flags.contains("cookie"))

        let store = CodexBarConfigStore()
        let (config, cleared) = Self.configClearingCredential(
            Self.loadConfig(output: output),
            provider: provider,
            fields: fields)
        // Nothing stored means nothing to write; a missing config file stays missing.
        if !cleared.isEmpty {
            do {
                try store.save(config)
            } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
            }
        }

        let result = ConfigClearCredentialResult(
            provider: provider.rawValue,
            cleared: cleared,
            configPath: store.fileURL.path)
        switch output.format {
        case .text:
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            if cleared.isEmpty {
                print("Config: no stored \(Self.configCredentialDescription(fields, joiner: "or")) for \(name)")
            } else {
                print("Config: cleared \(Self.configCredentialDescription(cleared, joiner: "and")) for \(name)")
            }
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    /// Clears both credentials unless a flag narrows the command to one of them.
    static func configCredentialFields(apiKey: Bool, cookie: Bool) -> [ConfigCredentialField] {
        guard apiKey || cookie else { return ConfigCredentialField.allCases }
        return ConfigCredentialField.allCases.filter { $0 == .apiKey ? apiKey : cookie }
    }

    static func configClearingCredential(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        fields: [ConfigCredentialField]) -> (config: CodexBarConfig, cleared: [ConfigCredentialField])
    {
        var updated = config.normalized()
        guard var providerConfig = updated.providerConfig(for: provider.instanceID) else { return (updated, []) }
        var cleared: [ConfigCredentialField] = []
        if fields.contains(.apiKey), providerConfig.apiKey != nil {
            providerConfig.apiKey = nil
            // Provider-specific by design: Settings drops Moonshot's key-bound region together with the key.
            if provider == .moonshot {
                providerConfig.apiKeyRegion = nil
            }
            cleared.append(.apiKey)
        }
        if fields.contains(.cookieHeader), providerConfig.cookieHeader != nil {
            providerConfig.cookieHeader = nil
            cleared.append(.cookieHeader)
        }
        guard !cleared.isEmpty else { return (updated, []) }
        updated.setProviderConfig(providerConfig)
        return (updated, cleared)
    }

    private static func configCredentialDescription(_ fields: [ConfigCredentialField], joiner: String) -> String {
        fields.map { $0 == .apiKey ? "API key" : "manual cookie" }.joined(separator: " \(joiner) ")
    }
}

struct ConfigClearCredentialOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.concreteOptionHelp)
    var provider: String?

    @Flag(name: .long("api-key"), help: "Clear only the stored API key")
    var apiKey: Bool = false

    @Flag(name: .long("cookie"), help: "Clear only the stored manual cookie")
    var cookie: Bool = false
}

private struct ConfigClearCredentialResult: Encodable {
    let provider: String
    let cleared: [ConfigCredentialField]
    let configPath: String
}
