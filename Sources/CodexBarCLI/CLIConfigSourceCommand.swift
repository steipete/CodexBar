import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runConfigSetSource(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let selection: (provider: UsageProvider, source: ProviderSourceMode)
        do {
            selection = try Self.configSourceSelection(
                provider: values.options["provider"]?.last,
                source: values.options["source"]?.last)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }
        let store = CodexBarConfigStore()
        let config = Self.configSettingSource(
            Self.loadConfig(output: output), provider: selection.provider, source: selection.source)
        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }
        let metadata = ProviderDescriptorRegistry.descriptor(for: selection.provider).metadata
        let result = ConfigSetSourceResult(
            provider: selection.provider.rawValue,
            displayName: metadata.displayName,
            enabled: config.providerConfig(for: selection.provider.instanceID)?.enabled ?? metadata.defaultEnabled,
            source: selection.source.rawValue,
            configPath: store.fileURL.path)
        switch output.format {
        case .text:
            print("Config: \(metadata.displayName) source set to \(selection.source.rawValue)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    static func configSourceSelection(
        provider rawProvider: String?, source rawSource: String?) throws
        -> (provider: UsageProvider, source: ProviderSourceMode)
    {
        guard let rawProvider,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else { throw CLIArgumentError("Unknown or missing provider. Use --provider <name>.") }
        guard let rawSource, let source = ProviderSourceMode(rawValue: rawSource.lowercased()) else {
            throw CLIArgumentError("Unknown or missing source. Use --source auto|web|cli|oauth|api.")
        }
        let supported = ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes
        guard supported.contains(source) else {
            let choices = supported.map(\.rawValue).sorted().joined(separator: ", ")
            throw CLIArgumentError("Source \(source.rawValue) is not supported for \(provider.rawValue). "
                + "Supported sources: \(choices).")
        }
        return (provider, source)
    }

    static func configSettingSource(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        source: ProviderSourceMode) -> CodexBarConfig
    {
        var updated = config.normalized()
        var entry = updated.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        entry.source = source == .auto ? nil : source
        updated.setProviderConfig(entry)
        return updated
    }
}

struct ConfigSetSourceOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?

    @Option(name: .long("source"), help: "Persistent source: auto, web, cli, oauth, or api")
    var source: String?
}

private struct ConfigSetSourceResult: Encodable {
    let provider: String
    let displayName: String
    let enabled: Bool
    let source: String
    let configPath: String
}
