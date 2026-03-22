import CodexBarCore
import Commander
import Foundation

private struct ConfigAddAccountPayload: Encodable {
    let provider: String
    let label: String
    let activeIndex: Int
    let count: Int
}

extension CodexBarCLI {
    static func runConfigAddAccount(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let store = CodexBarConfigStore()
        let config: CodexBarConfig
        do {
            config = try store.loadOrCreateDefault()
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        guard let provider = Self.decodeSingleProvider(from: values) else {
            Self.exit(
                code: .failure,
                message: "Error: --provider must be a single supported provider.",
                output: output,
                kind: .args)
        }
        guard TokenAccountSupportCatalog.support(for: provider) != nil else {
            Self.exit(
                code: .failure,
                message: "Error: \(provider.rawValue) does not support token accounts.",
                output: output,
                kind: .args)
        }

        let rawToken = values.options["token"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawToken.isEmpty else {
            Self.exit(code: .failure, message: "Error: --token is required.", output: output, kind: .args)
        }

        let rawLabel = values.options["label"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedConfig = Self.configByAddingTokenAccount(
            config,
            provider: provider,
            label: rawLabel,
            token: rawToken,
            activate: true)

        do {
            try store.save(updatedConfig)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let providerConfig = updatedConfig.providerConfig(for: provider)
        let accounts = providerConfig?.tokenAccounts?.accounts ?? []
        let addedAccount = accounts.last

        switch output.format {
        case .text:
            let label = addedAccount?.label ?? rawLabel ?? "Account"
            print("Added \(provider.rawValue) account '\(label)' (\(accounts.count) total).")
        case .json:
            let payload = ConfigAddAccountPayload(
                provider: provider.rawValue,
                label: addedAccount?.label ?? rawLabel ?? "",
                activeIndex: providerConfig?.tokenAccounts?.activeIndex ?? 0,
                count: accounts.count)
            Self.printJSON(payload, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

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

    private static func decodeSingleProvider(from values: ParsedValues) -> UsageProvider? {
        guard let raw = values.options["provider"]?.last else { return nil }
        guard case let .single(provider) = ProviderSelection(argument: raw) else { return nil }
        return provider
    }

    private static func configByAddingTokenAccount(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        label: String?,
        token: String,
        activate: Bool) -> CodexBarConfig
    {
        var updatedConfig = config
        var providerConfig = updatedConfig.providerConfig(for: provider) ?? ProviderConfig(id: provider)
        let existing = providerConfig.tokenAccounts
        let accounts = existing?.accounts ?? []
        let fallbackLabel = label?.isEmpty == false ? label! : "Account \(accounts.count + 1)"
        let account = ProviderTokenAccount(
            id: UUID(),
            label: fallbackLabel,
            token: token,
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)
        let activeIndex = activate ? accounts.count : (existing?.clampedActiveIndex() ?? 0)
        providerConfig.tokenAccounts = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: activeIndex)
        if TokenAccountSupportCatalog.support(for: provider)?.requiresManualCookieSource == true {
            providerConfig.cookieSource = .manual
        }
        updatedConfig.setProviderConfig(providerConfig)
        return updatedConfig
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
