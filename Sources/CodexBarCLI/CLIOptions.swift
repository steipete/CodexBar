import CodexBarCore
import Commander
import Foundation

// MARK: - Options & parsing helpers

struct UsageOptions: CommanderParsable {
    private static let sourceHelp: String = {
        #if os(macOS)
        "Data source: auto | web | cli | oauth | api (auto uses web then falls back on missing cookies)"
        #else
        "Data source: auto | web | cli | oauth | api (web/auto are macOS only)"
        #endif
    }()

    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Option(name: .long("account"), help: "Token account label to use (from config.json)")
    var account: String?

    @Option(name: .long("account-index"), help: "Token account index (1-based)")
    var accountIndex: Int?

    @Flag(name: .long("all-accounts"), help: "Fetch all token accounts for the provider")
    var allAccounts: Bool = false

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("no-credits"), help: "Skip Codex credits line")
    var noCredits: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("status"), help: "Fetch and include provider status")
    var status: Bool = false

    @Flag(name: .long("web"), help: "Alias for --source web")
    var web: Bool = false

    @Option(name: .long("source"), help: Self.sourceHelp)
    var source: String?

    @Option(name: .long("web-timeout"), help: "Web fetch timeout (seconds) (Codex only; source=auto|web)")
    var webTimeout: Double?

    @Flag(name: .long("web-debug-dump-html"), help: "Dump HTML snapshots to /tmp when Codex dashboard data is missing")
    var webDebugDumpHtml: Bool = false

    @Flag(name: .long("antigravity-plan-debug"), help: "Emit Antigravity planInfo fields (debug)")
    var antigravityPlanDebug: Bool = false

    @Flag(name: .long("augment-debug"), help: "Emit Augment API responses (debug)")
    var augmentDebug: Bool = false
}

enum ProviderSelection: Sendable, ExpressibleFromArgument {
    case single(UsageProvider)
    case both
    case all
    case custom([UsageProvider])

    init?(argument: String) {
        let normalized = argument.lowercased()
        switch normalized {
        case "both":
            self = .both
        case "all":
            self = .all
        default:
            if let provider = ProviderDescriptorRegistry.cliNameMap[normalized] {
                self = .single(provider)
            } else {
                return nil
            }
        }
    }

    init(provider: UsageProvider) {
        self = .single(provider)
    }

    var asList: [UsageProvider] {
        switch self {
        case let .single(provider):
            return [provider]
        case .both:
            let primary = ProviderDescriptorRegistry.all.filter(\ .metadata.isPrimaryProvider)
            if !primary.isEmpty {
                return primary.map(\ .id)
            }
            return ProviderDescriptorRegistry.all.prefix(2).map(\ .id)
        case .all:
            return ProviderDescriptorRegistry.all.map(\ .id)
        case let .custom(providers):
            return providers
        }
    }
}

enum OutputFormat: String, Sendable, ExpressibleFromArgument {
    case text
    case json

    init?(argument: String) {
        switch argument.lowercased() {
        case "text": self = .text
        case "json": self = .json
        default: return nil
        }
    }
}

enum ProviderHelp {
    static var list: String {
        let names = ProviderDescriptorRegistry.all.map(\ .cli.name)
        return (names + ["both", "all"]).joined(separator: "|")
    }

    static var optionHelp: String {
        "Provider to query: \(self.list)"
    }
}
