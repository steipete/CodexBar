import CodexBarCore
import Commander
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

struct PluginFetchOptions: CommanderParsable {
    @Argument(help: "Plugin provider instance ID")
    var id: String = ""

    @Flag(name: .long("json"), help: "Emit the generic UsageSnapshot as JSON")
    var json: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}

extension CodexBarCLI {
    static func runPlugins(path: [String], values: ParsedValues) async {
        let results = UserProviderPluginRegistry.refresh()
        switch path {
        case ["plugins", "list"]:
            for result in results {
                if let plugin = result.plugin {
                    print("\(plugin.manifest.id.rawValue)\t\(plugin.manifest.name)\t\(plugin.fileURL.path)")
                } else {
                    print("error\t\(result.fileURL.path)\t\(result.error ?? "Unknown error")")
                }
            }
        case ["plugins", "fetch"]:
            await self.fetchPlugin(values: values)
        default:
            Self.exit(code: .failure, message: "Unknown plugins command", kind: .args)
        }
    }

    private static func fetchPlugin(values: ParsedValues) async {
        guard let rawID = values.positional.first,
              let instanceID = ProviderInstanceID(rawValue: rawID),
              let plugin = UserProviderPluginRegistry.plugin(for: instanceID)
        else {
            exit(code: .failure, message: "Plugin was not found", kind: .args)
        }
        guard plugin.manifest.capabilities.contains(.browserCookies) == false else {
            Self.exit(
                code: .failure,
                message: "Browser-cookie plugins are supported by the macOS app only; CLI access fails closed.",
                kind: .provider)
        }

        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let pluginConfig = config.providerConfig(for: instanceID)
        let settings = pluginConfig?.pluginSettings ?? [:]
        let secrets = pluginConfig?.pluginSecrets ?? [:]
        let approvalStore = ProviderPluginApprovalStore()
        do {
            let binding = try plugin.approvalBinding(settings: settings)
            if !approvalStore.isApproved(binding) {
                guard Self.isInteractiveTerminal else {
                    throw UserProviderPluginError.approvalRequired(binding)
                }
                guard self.confirmPluginApproval(binding) else {
                    Self.exit(code: .failure, message: "Plugin approval cancelled", kind: .provider)
                }
                try approvalStore.record(binding)
            }
            let snapshot = try await plugin.fetchUsage(
                settings: settings,
                secrets: secrets,
                approvalStore: approvalStore)
            if values.flags.contains("json") {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if values.flags.contains("pretty") {
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                }
                let data = try encoder.encode(snapshot)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw ProviderPluginError.load("could not encode plugin snapshot as UTF-8")
                }
                print(json)
            } else {
                self.printPluginSnapshot(plugin: plugin, snapshot: snapshot)
            }
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, kind: .provider)
        }
    }

    private static var isInteractiveTerminal: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1
    }

    private static func confirmPluginApproval(_ binding: ProviderPluginApprovalBinding) -> Bool {
        writeStderr("Plugin \(binding.instanceID.rawValue) requests network access:\n")
        for origin in binding.origins {
            writeStderr("  origin: \(origin)\n")
        }
        writeStderr("  auth: \(binding.authMode)\n")
        writeStderr("  capabilities: \(binding.capabilities.joined(separator: ", "))\n")
        writeStderr("  secrets: \(binding.secretNames.joined(separator: ", "))\n")
        for domain in binding.cookieDomains {
            writeStderr("  cookie domain: \(domain)\n")
        }
        for origin in binding.typedConfirmationOrigins {
            writeStderr("Type \(origin) to confirm: ")
            guard readLine() == origin else { return false }
        }
        writeStderr("Approve? [y/N] ")
        return readLine()?.lowercased() == "y"
    }

    private static func printPluginSnapshot(plugin: UserProviderPlugin, snapshot: UsageSnapshot) {
        print(plugin.manifest.name)
        if let primary = snapshot.primary {
            print("Primary: \(Int(primary.usedPercent.rounded()))% used")
        }
        if let secondary = snapshot.secondary {
            print("Secondary: \(Int(secondary.usedPercent.rounded()))% used")
        }
        if let cost = snapshot.providerCost {
            print("Cost: \(cost.used) \(cost.currencyCode)")
        }
        for section in snapshot.details {
            if let title = section.title {
                print(title)
            }
            for row in section.rows {
                print("\(row.label): \(row.value)")
            }
        }
    }
}
