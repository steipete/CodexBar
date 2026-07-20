import AdaptiveReplayKit
import Foundation

enum ReplayPolicyName: String, CaseIterable, Sendable {
    case adaptive
    case adaptiveActivity = "adaptive-activity"
    case fixed2Minutes = "fixed-2m"
    case fixed5Minutes = "fixed-5m"
    case fixed15Minutes = "fixed-15m"
    case fixed30Minutes = "fixed-30m"
    case manual

    var policy: any ReplayPolicy {
        switch self {
        case .adaptive:
            AdaptiveReplayPolicy()
        case .adaptiveActivity:
            AgentAwareAdaptiveReplayPolicy()
        case .fixed2Minutes:
            FixedIntervalPolicy(minutes: 2)
        case .fixed5Minutes:
            FixedIntervalPolicy(minutes: 5)
        case .fixed15Minutes:
            FixedIntervalPolicy(minutes: 15)
        case .fixed30Minutes:
            FixedIntervalPolicy(minutes: 30)
        case .manual:
            ManualPolicy()
        }
    }

    static var expectedValues: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

enum CLIArguments {
    case run(
        tracePath: String,
        policyNames: [ReplayPolicyName],
        jsonOutput: Bool,
        gapGraceSeconds: TimeInterval?)
    case help(exitCode: Int32)
    case invalid(message: String)

    static func parse(_ arguments: [String]) -> Self {
        if arguments.contains("-h") || arguments.contains("--help") {
            return .help(exitCode: EXIT_SUCCESS)
        }

        var tracePath: String?
        var policyNames: [ReplayPolicyName] = []
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
                let rawPolicyName = arguments[index]
                guard let policyName = ReplayPolicyName(rawValue: rawPolicyName) else {
                    return .invalid(
                        message: "unknown policy '\(rawPolicyName)' (expected: \(ReplayPolicyName.expectedValues))")
                }
                policyNames.append(policyName)
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
            policyNames: policyNames.isEmpty ? ReplayPolicyName.allCases : policyNames,
            jsonOutput: jsonOutput,
            gapGraceSeconds: gapGraceSeconds)
    }
}
