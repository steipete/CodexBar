import AdaptiveReplayKit
import Foundation

enum CLIArguments {
    case run(tracePath: String, policyNames: [String], jsonOutput: Bool, gapGraceSeconds: TimeInterval?)
    case help(exitCode: Int32)
    case invalid(message: String)

    private static let allPolicyNames = [
        "adaptive", "adaptive-activity", "fixed-2m", "fixed-5m", "fixed-15m", "fixed-30m", "manual",
    ]

    static func parse(_ arguments: [String]) -> Self {
        if arguments.contains("-h") || arguments.contains("--help") {
            return .help(exitCode: EXIT_SUCCESS)
        }

        var tracePath: String?
        var policyNames: [String] = []
        var jsonOutput = false
        var gapGraceSeconds: TimeInterval? = ReplayTraceSegmenter.defaultGraceSeconds
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                jsonOutput = true
            case "--raw-wall-clock":
                gapGraceSeconds = nil
            case "--gap-grace":
                index += 1
                guard index < arguments.count,
                      let seconds = TimeInterval(arguments[index]),
                      seconds >= 0,
                      seconds.isFinite
                else { return .invalid(message: "--gap-grace requires non-negative finite seconds") }
                gapGraceSeconds = seconds
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
            policyNames: policyNames.isEmpty ? Self.allPolicyNames : policyNames,
            jsonOutput: jsonOutput,
            gapGraceSeconds: gapGraceSeconds)
    }
}
