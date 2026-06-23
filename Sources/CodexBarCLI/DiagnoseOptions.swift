import CodexBarCore
import Commander
import Foundation

struct DiagnoseOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?

    @Option(name: .long("format"), help: "Output format: json")
    var format: String?

    @Flag(name: .long("redact"), help: "Explicitly redact sensitive values (always enabled for diagnose)")
    var redact: Bool = false

    @Option(name: .long("output"), help: "Write redacted JSON diagnostic export to a file")
    var output: String?

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}
