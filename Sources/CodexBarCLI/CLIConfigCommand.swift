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
