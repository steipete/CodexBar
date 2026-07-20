import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runHooks(path: [String], values: ParsedValues) async {
        switch path {
        case ["hooks", "list"]:
            self.runHooksList(values)
        case ["hooks", "enable"]:
            self.runHooksSetEnabled(values, enabled: true)
        case ["hooks", "disable"]:
            self.runHooksSetEnabled(values, enabled: false)
        case ["hooks", "test"]:
            await self.runHooksTest(values)
        default:
            self.exit(
                code: .failure,
                message: "Unknown command",
                output: CLIOutputPreferences.from(values: values),
                kind: .args)
        }
    }

    static func runHooksList(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let hooks = Self.loadConfig(output: output).hooks ?? HooksConfig()

        switch output.format {
        case .text:
            print("Hooks: \(hooks.enabled ? "enabled" : "disabled")")
            if hooks.events.isEmpty {
                print("No rules configured.")
            } else {
                for rule in hooks.events {
                    let provider = rule.provider ?? "any"
                    let state = rule.enabled ? "on" : "off"
                    let command = ([rule.executable] + rule.arguments).joined(separator: " ")
                    print("[\(state)] \(rule.event.rawValue) provider=\(provider): \(command)")
                }
            }
        case .json:
            Self.printJSON(hooks, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runHooksSetEnabled(_ values: ParsedValues, enabled: Bool) {
        let output = CLIOutputPreferences.from(values: values)
        let store = CodexBarConfigStore()
        var config = Self.loadConfig(output: output)
        var hooks = config.hooks ?? HooksConfig()
        hooks.enabled = enabled
        config.hooks = hooks

        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        switch output.format {
        case .text:
            print("Hooks: \(enabled ? "enabled" : "disabled")")
        case .json:
            Self.printJSON(hooks, pretty: output.pretty)
        }

        Self.exit(code: .success, output: output, kind: .config)
    }

    static func runHooksTest(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)

        guard let rawEvent = values.positional.first,
              let eventType = HookEventType(rawValue: rawEvent)
        else {
            let names = HookEventType.allCases.map(\.rawValue).joined(separator: ", ")
            Self.exit(
                code: .failure,
                message: "Unknown or missing event. Use one of: \(names).",
                output: output,
                kind: .args)
        }

        guard let rawProvider = values.options["provider"]?.last,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            Self.exit(
                code: .failure,
                message: "Unknown or missing provider. Use --provider <name>.",
                output: output,
                kind: .args)
        }

        let event = Self.sampleHookEvent(type: eventType, provider: provider.rawValue)
        let hooks = Self.loadConfig(output: output).hooks ?? HooksConfig()
        let rules = hooks.matchingRules(for: event)

        guard !rules.isEmpty else {
            Self.exit(
                code: .failure,
                message: hooks.enabled
                    ? "No hook rule matches \(eventType.rawValue) for \(provider.rawValue)."
                    : "Hooks are disabled.",
                output: output,
                kind: .config)
        }

        var results: [HookTestResult] = []
        for rule in rules {
            do {
                let result = try await HookRunner.run(rule: rule, event: event)
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(HookTestResult(
                    ruleID: rule.id,
                    executable: rule.executable,
                    event: eventType.rawValue,
                    provider: provider.rawValue,
                    success: true,
                    stdout: stdout.isEmpty ? nil : stdout,
                    error: nil))
                if !output.usesJSONOutput {
                    print("ran \(rule.executable): OK\(stdout.isEmpty ? "" : " — \(stdout)")")
                }
            } catch {
                let summary = HookRunner.failureSummary(error)
                results.append(HookTestResult(
                    ruleID: rule.id,
                    executable: rule.executable,
                    event: eventType.rawValue,
                    provider: provider.rawValue,
                    success: false,
                    stdout: nil,
                    error: summary))
                if !output.usesJSONOutput {
                    Self.writeStderr("ran \(rule.executable): \(summary)\n")
                }
            }
        }

        if output.usesJSONOutput {
            Self.printJSON(results, pretty: output.pretty)
        }
        let succeeded = results.allSatisfy(\.success)
        Self.exit(code: succeeded ? .success : .failure, output: output, kind: .runtime)
    }

    /// A representative event for `hooks test`: quota events report high usage so a
    /// thresholded `quota_low` rule fires; reset reports empty usage.
    static func sampleHookEvent(type: HookEventType, provider: String) -> HookEvent {
        let usagePercent: Double?
        let status: String?
        switch type {
        case .quotaLow, .quotaReached:
            usagePercent = 1
            status = nil
        case .quotaReset:
            usagePercent = 0
            status = nil
        case .providerUnavailable:
            usagePercent = nil
            status = "major"
        case .providerRecovered:
            usagePercent = nil
            status = "none"
        case .refreshFailed:
            usagePercent = nil
            status = "error"
        }
        return HookEvent(
            event: type,
            provider: provider,
            window: type == .quotaReached || type == .quotaLow || type == .quotaReset ? "session" : nil,
            usagePercent: usagePercent,
            status: status,
            timestamp: Date())
    }
}

struct HookTestResult: Codable, Sendable, Equatable {
    let ruleID: String
    let executable: String
    let event: String
    let provider: String
    let success: Bool
    let stdout: String?
    let error: String?
}

struct HooksOptions: CommanderParsable {
    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "Emit JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}

struct HooksTestOptions: CommanderParsable {
    @Argument(help: "Event name (e.g. quota_reached)")
    var event: String = ""

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "Emit JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}
