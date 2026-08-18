import Commander
import Foundation

struct ResolvedOutputFormat {
    let format: OutputFormat
    let toonRequested: Bool
}

struct CLIOutputPreferences {
    let format: OutputFormat
    let jsonOnly: Bool
    let pretty: Bool
    /// Set only by `usage --format toon`. TOON piggybacks on the JSON fetch/render pipeline (`format`
    /// stays `.json` so credits/color/account behavior matches), but error/exit payloads must still
    /// render as TOON rather than JSON so callers parsing `--format toon` see a consistent format.
    var toonRequested: Bool = false

    var usesJSONOutput: Bool {
        self.jsonOnly || self.format == .json
    }

    /// TOON is a `usage`-only contract. Every other command's `--format` help promises `text | json`,
    /// so they must keep the legacy decoder, where an unrecognized value falls through to the
    /// text/JSON default instead of silently selecting JSON.
    static func from(values: ParsedValues, allowsToon: Bool = false) -> CLIOutputPreferences {
        let jsonOnly = values.flags.contains("jsonOnly")
        let pretty = values.flags.contains("pretty")
        let resolved = Self.resolveOutputFormat(from: values, allowsToon: allowsToon)
        return CLIOutputPreferences(
            format: resolved.format,
            jsonOnly: jsonOnly,
            pretty: pretty,
            toonRequested: resolved.toonRequested)
    }

    static func from(argv: [String]) -> CLIOutputPreferences {
        var jsonOnly = false
        var pretty = false
        var lastExplicitFormat: String?
        var jsonShortcut = false

        var index = 0
        while index < argv.count {
            let arg = argv[index]
            switch arg {
            case "--json-only":
                jsonOnly = true
                jsonShortcut = true
            case "--json":
                jsonShortcut = true
            case "--pretty":
                pretty = true
            case "--format":
                let next = index + 1
                if next < argv.count {
                    lastExplicitFormat = argv[next]
                    index += 1
                }
            default:
                if arg.hasPrefix("--format="), arg != "--format=" {
                    lastExplicitFormat = String(arg.dropFirst("--format=".count))
                }
            }
            index += 1
        }

        let resolved = Self.resolveOutputFormat(
            lastExplicitFormat: lastExplicitFormat,
            jsonShortcut: jsonShortcut || jsonOnly,
            allowsToon: Self.commandSupportsToon(argv: argv))
        return CLIOutputPreferences(
            format: resolved.format,
            jsonOnly: jsonOnly,
            pretty: pretty,
            toonRequested: resolved.toonRequested)
    }

    /// Mirrors `CodexBarCLI.effectiveArgv`: a bare `codexbar --format toon` runs the implicit `usage`
    /// command, so the argv bootstrap scanner has to reach the same verdict as the post-parse path.
    static func commandSupportsToon(argv: [String]) -> Bool {
        guard let first = argv.first else { return true }
        if first.hasPrefix("-") { return true }
        return first == "usage"
    }

    /// Explicit `--format` wins over `--json` / `--json-only`, matching `decodeFormat(from:)`.
    /// TOON is recognized only via `usage --format toon` and piggybacks on the JSON pipeline; for
    /// every other command `toon` stays an unrecognized value, exactly as before TOON existed.
    static func resolveOutputFormat(from values: ParsedValues, allowsToon: Bool = false) -> ResolvedOutputFormat {
        let jsonShortcut = values.flags.contains("jsonShortcut")
            || values.flags.contains("json")
            || values.flags.contains("jsonOnly")
        return Self.resolveOutputFormat(
            lastExplicitFormat: values.options["format"]?.last,
            jsonShortcut: jsonShortcut,
            allowsToon: allowsToon)
    }

    static func resolveOutputFormat(
        lastExplicitFormat: String?,
        jsonShortcut: Bool,
        allowsToon: Bool = false) -> ResolvedOutputFormat
    {
        if let raw = lastExplicitFormat {
            if allowsToon, raw.lowercased() == "toon" {
                return ResolvedOutputFormat(format: .json, toonRequested: true)
            }
            if let parsed = OutputFormat(argument: raw) {
                return ResolvedOutputFormat(format: parsed, toonRequested: false)
            }
        }
        if jsonShortcut {
            return ResolvedOutputFormat(format: .json, toonRequested: false)
        }
        return ResolvedOutputFormat(format: .text, toonRequested: false)
    }
}
