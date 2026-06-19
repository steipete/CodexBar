import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runConfigValidate(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let issues = CodexBarConfigValidator.validate(config)
        let hasErrors = issues.contains(where: { $0.severity == .error })

        switch output.format {
        case .text:
            if issues.isEmpty {
                print("Config: OK")
            } else {
                for issue in issues {
                    let provider = issue.provider?.rawValue ?? "config"
                    let field = issue.field ?? ""
                    let prefix = "[\(issue.severity.rawValue.uppercased())]"
                    let suffix = field.isEmpty ? "" : " (\(field))"
                    print("\(prefix) \(provider)\(suffix): \(issue.message)")
                }
            }
        case .json:
            Self.printJSON(issues, pretty: output.pretty)
        }

        Self.exit(code: hasErrors ? .failure : .success, output: output, kind: .config)
    }

    static func runConfigDump(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        Self.printJSON(config, pretty: output.pretty)
        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runConfigProviders(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let results = Self.configProviderStatuses(config)

        switch output.format {
        case .text:
            for result in results {
                let state = result.enabled ? "enabled" : "disabled"
                let marker = result.defaultEnabled ? " default" : ""
                print("\(result.provider): \(state)\(marker) (\(result.displayName))")
            }
        case .json:
            Self.printJSON(results, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runConfigSetProviderEnabled(_ values: ParsedValues, enabled: Bool) {
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

        let store = CodexBarConfigStore()
        var config = Self.loadConfig(output: output)
        config = Self.configSettingProviderEnabled(config, provider: provider, enabled: enabled)

        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let result = ConfigProviderToggleResult(
            provider: provider.rawValue,
            displayName: metadata.displayName,
            enabled: enabled,
            configPath: store.fileURL.path)

        switch output.format {
        case .text:
            let state = enabled ? "enabled" : "disabled"
            print("Config: \(state) \(metadata.displayName)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runConfigSetAPIKey(_ values: ParsedValues) {
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
        guard ProviderConfigEnvironment.supportsAPIKeyOverride(for: provider) else {
            Self.exit(
                code: .failure,
                message: "\(rawProvider) does not support config API keys.",
                output: output,
                kind: .args)
        }

        let apiKey: String
        do {
            apiKey = try Self.resolveConfigAPIKeyInput(
                apiKey: values.options["apiKey"]?.last,
                readFromStdin: values.flags.contains("stdin"))
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }

        let enableProvider = !values.flags.contains("noEnable")
        let store = CodexBarConfigStore()
        var config = Self.loadConfig(output: output)
        config = Self.configSettingAPIKey(
            config,
            provider: provider,
            apiKey: apiKey,
            enableProvider: enableProvider)

        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let result = ConfigSetAPIKeyResult(
            provider: provider.rawValue,
            enabled: config.providerConfig(for: provider)?.enabled ?? false,
            configPath: store.fileURL.path)

        switch output.format {
        case .text:
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            let suffix = result.enabled ? " and enabled" : ""
            print("Config: stored API key for \(name)\(suffix)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func resolveConfigAPIKeyInput(apiKey: String?, readFromStdin: Bool) throws -> String {
        if apiKey != nil, readFromStdin {
            throw CLIArgumentError("Use either --api-key or --stdin, not both.")
        }

        let raw: String? = if readFromStdin {
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        } else {
            apiKey
        }

        guard let value = Self.cleanConfigSecret(raw) else {
            throw CLIArgumentError("Missing API key. Pass --api-key <key> or pipe it with --stdin.")
        }
        return value
    }

    static func configSettingAPIKey(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        apiKey: String,
        enableProvider: Bool) -> CodexBarConfig
    {
        var updated = config.normalized()
        var providerConfig = updated.providerConfig(for: provider) ?? ProviderConfig(id: provider)
        providerConfig.apiKey = apiKey
        if enableProvider {
            providerConfig.enabled = true
        }
        updated.setProviderConfig(providerConfig)
        return updated
    }

    static func configSettingProviderEnabled(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        enabled: Bool) -> CodexBarConfig
    {
        var updated = config.normalized()
        var providerConfig = updated.providerConfig(for: provider) ?? ProviderConfig(id: provider)
        providerConfig.enabled = enabled
        updated.setProviderConfig(providerConfig)
        return updated
    }

    static func configProviderStatuses(_ config: CodexBarConfig) -> [ConfigProviderStatusResult] {
        let metadata = ProviderDescriptorRegistry.metadata
        return config.normalized().providers.map { providerConfig in
            let meta = metadata[providerConfig.id]
            let defaultEnabled = meta?.defaultEnabled ?? false
            return ConfigProviderStatusResult(
                provider: providerConfig.id.rawValue,
                displayName: meta?.displayName ?? providerConfig.id.rawValue,
                enabled: providerConfig.enabled ?? defaultEnabled,
                defaultEnabled: defaultEnabled)
        }
    }

    private static func cleanConfigSecret(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct ConfigOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}

struct ConfigSetAPIKeyOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?

    @Option(name: .long("api-key"), help: "API key to store")
    var apiKey: String?

    @Flag(name: .long("stdin"), help: "Read API key from stdin")
    var stdin: Bool = false

    @Flag(name: .long("no-enable"), help: "Store the key without enabling the provider")
    var noEnable: Bool = false
}

struct ConfigProviderToggleOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?
}

private struct ConfigSetAPIKeyResult: Encodable {
    let provider: String
    let enabled: Bool
    let configPath: String
}

struct ConfigProviderStatusResult: Encodable, Equatable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let defaultEnabled: Bool
}

private struct ConfigProviderToggleResult: Encodable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let configPath: String
}
