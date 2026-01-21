import Commander
import Foundation

struct CLIOutputPreferences: Sendable {
    let format: OutputFormat
    let jsonOnly: Bool
    let pretty: Bool

    var usesJSONOutput: Bool {
        self.jsonOnly || self.format == .json
    }

    static func from(values: ParsedValues) -> CLIOutputPreferences {
        let jsonOnly = values.flags.contains("jsonOnly")
        let format = CodexBarCLI.decodeFormat(from: values)
        let pretty = values.flags.contains("pretty")
        return CLIOutputPreferences(format: format, jsonOnly: jsonOnly, pretty: pretty)
    }

    static func from(argv: [String]) -> CLIOutputPreferences {
        var jsonOnly = false
        var pretty = false
        var format: OutputFormat = .text

        var index = 0
        while index < argv.count {
            let arg = argv[index]
            switch arg {
            case "--json-only":
                jsonOnly = true
                format = .json
            case "--json":
                format = .json
            case "--pretty":
                pretty = true
            case "--format":
                let next = index + 1
                if next < argv.count, let parsed = OutputFormat(argument: argv[next]) {
                    format = parsed
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        return CLIOutputPreferences(format: format, jsonOnly: jsonOnly, pretty: pretty)
    }
}
