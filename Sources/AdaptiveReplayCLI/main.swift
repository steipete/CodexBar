import AdaptiveReplayKit
import Foundation

/// Thin CLI shell over `AdaptiveReplayKit`: parses a trace path and a policy name, runs the
/// replay, and prints the resulting `ReplayMetrics`. All parsing/replay/metrics logic lives in
/// the library — this file only routes arguments to it and formats the result.
enum AdaptiveReplayCLI {
    static func main() {
        let arguments = CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))

        switch arguments {
        case let .help(exitCode):
            print(Self.helpText)
            exit(exitCode)
        case let .invalid(message):
            FileHandle.standardError.write(Data("error: \(message)\n\n\(Self.helpText)\n".utf8))
            exit(EXIT_FAILURE)
        case let .run(tracePath, policyNames, jsonOutput):
            Self.run(tracePath: tracePath, policyNames: policyNames, jsonOutput: jsonOutput)
        }
    }

    private static func run(tracePath: String, policyNames: [String], jsonOutput: Bool) {
        let records: [AdaptiveRefreshTraceRecord]
        do {
            records = try AdaptiveRefreshTraceParser.parse(contentsOf: URL(fileURLWithPath: tracePath))
        } catch {
            FileHandle.standardError.write(Data("error: failed to parse trace: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }

        let policies: [any ReplayPolicy]
        do {
            policies = try policyNames.map { try Self.policy(named: $0) }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }

        let results = policies.map { ReplayEngine.run(trace: records, policy: $0) }

        if jsonOutput {
            print(Self.renderJSON(results))
        } else {
            print(Self.renderTable(results))
        }
    }

    private static func policy(named name: String) throws -> any ReplayPolicy {
        if name == "adaptive" { return MirroredAdaptivePolicy() }
        if name == "manual" { return ManualPolicy() }
        if name.hasPrefix("fixed-"), name.hasSuffix("m"),
           let minutes = Int(name.dropFirst("fixed-".count).dropLast())
        {
            return FixedIntervalPolicy(minutes: minutes)
        }
        throw CLIError.unknownPolicy(name)
    }

    private static func renderTable(_ results: [ReplayMetrics]) -> String {
        var lines: [String] = []
        let header = [
            "policy", "refreshes", "per24h", "advances", "staleness p50", "staleness p95", "constrained ok",
        ]
        lines.append(header.joined(separator: "\t"))
        for metrics in results {
            let staleness = metrics.stalenessAtMenuOpen
            lines.append([
                metrics.policyName,
                String(metrics.totalRefreshCount),
                String(format: "%.2f", metrics.refreshCountPer24h),
                String(metrics.interactionAdvanceCount),
                staleness.map { String(format: "%.0fs", $0.median) } ?? "n/a",
                staleness.map { String(format: "%.0fs", $0.p95) } ?? "n/a",
                metrics.constrainedCompliance
                    .isCompliant ? "yes" : "NO (\(metrics.constrainedCompliance.violationCount))",
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderJSON(_ results: [ReplayMetrics]) -> String {
        let payload = results.map { metrics -> [String: Any] in
            var dict: [String: Any] = [
                "policy": metrics.policyName,
                "simulatedSpanSeconds": metrics.simulatedSpanSeconds,
                "totalRefreshCount": metrics.totalRefreshCount,
                "refreshCountPer24h": metrics.refreshCountPer24h,
                "interactionAdvanceCount": metrics.interactionAdvanceCount,
                "constrainedDecisionCount": metrics.constrainedCompliance.constrainedDecisionCount,
                "constrainedViolationCount": metrics.constrainedCompliance.violationCount,
                "constrainedCompliant": metrics.constrainedCompliance.isCompliant,
            ]
            if let staleness = metrics.stalenessAtMenuOpen {
                dict["stalenessMeanSeconds"] = staleness.mean
                dict["stalenessMedianSeconds"] = staleness.median
                dict["stalenessP95Seconds"] = staleness.p95
                dict["stalenessSampleCount"] = staleness.sampleCount
            }
            return dict
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    private static let helpText = """
    Usage: adaptive-replay-cli <trace.jsonl> [--policy <name>]... [--json]

    Replays a JSONL adaptive-refresh trace against one or more refresh-timing policies and prints
    per-policy metrics: total refresh count, refresh count per 24h, how many of those refreshes were
    pulled forward by a menu-open interaction, staleness at menu-open (median/p95 seconds since the
    last simulated refresh), and constrained-tier compliance.

    Policies:
      adaptive       The current adaptive table, mirrored from AdaptiveRefreshPolicy. Advances on
                     menu-open interactions, same as UsageStore.noteMenuOpened(at:).
      fixed-2m       Fixed 2 minute cadence. Unaffected by menu-open interactions.
      fixed-5m       Fixed 5 minute cadence.
      fixed-15m      Fixed 15 minute cadence.
      fixed-30m      Fixed 30 minute cadence.
      manual         Never refreshes (degenerate floor).

    Defaults to comparing all six policies when --policy is omitted.

    Options:
      --policy <name>   Restrict to one policy; repeat to compare a specific subset.
      --json            Print machine-readable JSON instead of a table.
      -h, --help        Print this help text.
    """
}

private enum CLIError: Error, CustomStringConvertible {
    case unknownPolicy(String)

    var description: String {
        switch self {
        case let .unknownPolicy(name):
            "unknown policy '\(name)' (expected: adaptive, manual, fixed-<N>m)"
        }
    }
}

private enum CLIArguments {
    case run(tracePath: String, policyNames: [String], jsonOutput: Bool)
    case help(exitCode: Int32)
    case invalid(message: String)

    static let allPolicyNames = ["adaptive", "fixed-2m", "fixed-5m", "fixed-15m", "fixed-30m", "manual"]

    static func parse(_ arguments: [String]) -> Self {
        if arguments.contains("-h") || arguments.contains("--help") {
            return .help(exitCode: EXIT_SUCCESS)
        }

        var tracePath: String?
        var policyNames: [String] = []
        var jsonOutput = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                jsonOutput = true
            case "--policy":
                index += 1
                guard index < arguments.count else { return .invalid(message: "--policy requires a value") }
                policyNames.append(arguments[index])
            default:
                guard tracePath == nil else {
                    return .invalid(message: "unexpected argument '\(argument)'")
                }
                tracePath = argument
            }
            index += 1
        }

        guard let tracePath else {
            return .help(exitCode: EXIT_FAILURE)
        }
        return .run(
            tracePath: tracePath,
            policyNames: policyNames.isEmpty ? self.allPolicyNames : policyNames,
            jsonOutput: jsonOutput)
    }
}

AdaptiveReplayCLI.main()
