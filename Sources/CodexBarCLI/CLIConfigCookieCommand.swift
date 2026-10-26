import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runConfigSetCookie(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let provider: UsageProvider
        let cookieHeader: String
        do {
            provider = try Self.configCookieProvider(values.options["provider"]?.last)
            cookieHeader = try Self.resolveConfigCookieInput(
                cookie: values.options["cookie"]?.last,
                readFromStdin: values.flags.contains("stdin"))
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }

        let store = CodexBarConfigStore()
        let config = Self.configSettingCookie(
            Self.loadConfig(output: output),
            provider: provider,
            cookieHeader: cookieHeader,
            enableProvider: !values.flags.contains("noEnable"))
        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let result = ConfigSetCookieResult(
            provider: provider.rawValue,
            enabled: config.providerConfig(for: provider.instanceID)?.enabled ?? metadata.defaultEnabled,
            configPath: store.fileURL.path)
        switch output.format {
        case .text:
            let suffix = result.enabled ? " and enabled" : ""
            print("Config: stored manual cookie for \(metadata.displayName)\(suffix)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    static func configCookieProvider(_ rawProvider: String?) throws -> UsageProvider {
        guard let rawProvider,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else { throw CLIArgumentError("Unknown or missing provider. Use --provider <name>.") }
        guard Self.readsConfigCookieHeader(provider) else {
            throw CLIArgumentError("\(rawProvider) does not support config cookies.")
        }
        return provider
    }

    /// Config cookies need a registered consumer; a web source may only support selected browser profiles.
    static func readsConfigCookieHeader(_ provider: UsageProvider) -> Bool {
        if ProviderDescriptorRegistry.descriptor(for: provider).settingsSection.supportsConfigCookieHeader {
            return true
        }
        let probe = "codexbar-probe=1"
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: provider,
            config: ProviderConfig(id: provider.instanceID, cookieHeader: probe, cookieSource: .manual))
        return environment.values.contains { $0.contains(probe) }
    }

    static func resolveConfigCookieInput(cookie: String?, readFromStdin: Bool) throws -> String {
        if cookie != nil, readFromStdin {
            throw CLIArgumentError("Use either --cookie or --stdin, not both.")
        }

        let raw: String? = if readFromStdin {
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        } else {
            cookie
        }

        guard let value = SettingsValue.cleaned(raw) else {
            throw CLIArgumentError("Missing cookie. Pass --cookie <header> or pipe it with --stdin.")
        }
        guard !value.contains(where: \.isNewline) else {
            throw CLIArgumentError("Cookie header must be a single line.")
        }
        return value
    }

    static func configSettingCookie(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        cookieHeader: String,
        enableProvider: Bool) -> CodexBarConfig
    {
        var updated = config.normalized()
        var providerConfig = updated.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        providerConfig.cookieHeader = cookieHeader
        providerConfig.cookieSource = .manual
        if enableProvider {
            providerConfig.enabled = true
        }
        updated.setProviderConfig(providerConfig)
        return updated
    }
}

struct ConfigSetCookieOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.concreteOptionHelp)
    var provider: String?

    @Option(name: .long("cookie"), help: "Cookie header to store")
    var cookie: String?

    @Flag(name: .long("stdin"), help: "Read cookie header from stdin")
    var stdin: Bool = false

    @Flag(name: .long("no-enable"), help: "Store the cookie without enabling the provider")
    var noEnable: Bool = false
}

private struct ConfigSetCookieResult: Encodable {
    let provider: String
    let enabled: Bool
    let configPath: String
}
