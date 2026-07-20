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
        case let .run(tracePath, policyNames, jsonOutput, gapGraceSeconds):
            Self.run(
                tracePath: tracePath,
                policyNames: policyNames,
                jsonOutput: jsonOutput,
                gapGraceSeconds: gapGraceSeconds)
        }
    }

    private static func run(
        tracePath: String,
        policyNames: [ReplayPolicyName],
        jsonOutput: Bool,
        gapGraceSeconds: TimeInterval?)
    {
        let records: [AdaptiveRefreshTraceRecord]
        do {
            records = try AdaptiveRefreshTraceParser.parse(contentsOf: URL(fileURLWithPath: tracePath))
        } catch {
            FileHandle.standardError.write(Data("error: failed to parse trace: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }

        let policies = policyNames.map(\.policy)

        let results = policies.map { policy in
            gapGraceSeconds.map {
                ReplayEngine.runSegmented(trace: records, policy: policy, graceSeconds: $0)
            } ?? ReplayEngine.run(trace: records, policy: policy)
        }
        let activityCoverage = ActivityCoverageStats.compute(from: records)
        let recordedScheduleAudit = RecordedScheduleAuditor.audit(records)

        if jsonOutput {
            print(Self.renderJSON(
                results,
                activityCoverage: activityCoverage,
                recordedScheduleAudit: recordedScheduleAudit,
                gapGraceSeconds: gapGraceSeconds))
        } else {
            print(Self.renderTable(results))
            print(Self.renderActivityCoverage(activityCoverage))
            print(Self.renderRecordedScheduleAudit(recordedScheduleAudit))
            if let gapGraceSeconds, let first = results.first {
                print(String(
                    format: "segmentation: %d segments, %.2fh excluded (legacy heuristic, %.0fs grace)",
                    first.segmentCount,
                    first.excludedGapSeconds / 3600,
                    gapGraceSeconds))
            } else {
                print("segmentation: disabled (raw wall clock)")
            }
        }
    }

    private static func renderRecordedScheduleAudit(_ audit: RecordedScheduleAudit) -> String {
        "recorded schedule: \(audit.recordedAdvanceCount) advances, "
            + "\(audit.acceptedEvaluationCount)/\(audit.evaluatedCount) evaluations accepted, "
            + "payload=\(audit.payloadMismatchCount) decision=\(audit.decisionMismatchCount) "
            + "menu-link=\(audit.menuLinkMismatchCount) mismatches, "
            + "ambiguous=\(audit.ambiguousComparisonCount)"
    }

    /// Reports coverage of optional activity observations already present in the input trace.
    private static func renderActivityCoverage(_ stats: ActivityCoverageStats) -> String {
        guard stats.decisionCount > 0 else {
            return "activity telemetry: no decision events in trace"
        }
        let sampledSummary = String(
            format: "%d/%d decisions sampled (%.0f%%)",
            stats.sampledCount,
            stats.decisionCount,
            stats.sampledFraction * 100)
        let activeSummary = String(
            format: "%d/%d active coding at decision time (%.0f%%)",
            stats.activeCount,
            stats.sampledCount,
            stats.activeFraction * 100)
        return "activity telemetry: \(sampledSummary), \(activeSummary)"
    }

    private static func renderTable(_ results: [ReplayMetrics]) -> String {
        var lines: [String] = []
        let header = [
            "policy", "refreshes", "per24h", "sim advances", "active >5m", "staleness p50",
            "staleness p95", "constrained ok",
        ]
        lines.append(header.joined(separator: "\t"))
        for metrics in results {
            let staleness = metrics.stalenessAtMenuOpen
            lines.append([
                metrics.policyName,
                String(metrics.totalRefreshCount),
                String(format: "%.2f", metrics.refreshCountPer24h),
                String(metrics.interactionAdvanceCount),
                "\(metrics.codingActiveDelayViolationCount)/\(metrics.codingActiveDecisionCount)",
                staleness.map { String(format: "%.0fs", $0.median) } ?? "n/a",
                staleness.map { String(format: "%.0fs", $0.p95) } ?? "n/a",
                metrics.constrainedCompliance
                    .isCompliant ? "yes" : "NO (\(metrics.constrainedCompliance.violationCount))",
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderJSON(
        _ results: [ReplayMetrics],
        activityCoverage: ActivityCoverageStats,
        recordedScheduleAudit: RecordedScheduleAudit,
        gapGraceSeconds: TimeInterval?) -> String
    {
        let policies = results.map { metrics -> [String: Any] in
            var dict: [String: Any] = [
                "policy": metrics.policyName,
                "simulatedSpanSeconds": metrics.simulatedSpanSeconds,
                "totalRefreshCount": metrics.totalRefreshCount,
                "refreshCountPer24h": metrics.refreshCountPer24h,
                "interactionAdvanceCount": metrics.interactionAdvanceCount,
                "codingActiveDecisionCount": metrics.codingActiveDecisionCount,
                "codingActiveDelayViolationCount": metrics.codingActiveDelayViolationCount,
                "segmentCount": metrics.segmentCount,
                "excludedGapSeconds": metrics.excludedGapSeconds,
                "boundaryCensoredMenuOpenCount": metrics.boundaryCensoredMenuOpenCount,
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
        let segmentation: [String: Any] = [
            "mode": gapGraceSeconds == nil ? "rawWallClock" : "legacyGapHeuristic",
            "gapGraceSeconds": gapGraceSeconds.map { $0 as Any } ?? NSNull(),
        ]
        let payload: [String: Any] = [
            "policies": policies,
            "activityCoverage": [
                "decisionCount": activityCoverage.decisionCount,
                "sampledCount": activityCoverage.sampledCount,
                "activeCount": activityCoverage.activeCount,
                "sampledFraction": activityCoverage.sampledFraction,
                "activeFraction": activityCoverage.activeFraction,
            ],
            "recordedScheduleAudit": [
                "recordedAdvanceCount": recordedScheduleAudit.recordedAdvanceCount,
                "evaluatedCount": recordedScheduleAudit.evaluatedCount,
                "acceptedEvaluationCount": recordedScheduleAudit.acceptedEvaluationCount,
                "rejectedEvaluationCount": recordedScheduleAudit.rejectedEvaluationCount,
                "payloadMismatchCount": recordedScheduleAudit.payloadMismatchCount,
                "decisionMismatchCount": recordedScheduleAudit.decisionMismatchCount,
                "menuLinkMismatchCount": recordedScheduleAudit.menuLinkMismatchCount,
                "ambiguousComparisonCount": recordedScheduleAudit.ambiguousComparisonCount,
                "isValid": recordedScheduleAudit.isValid,
            ],
            "segmentation": segmentation,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static let helpText = """
    Usage: AdaptiveReplayCLI <trace.jsonl> [--policy <name>]... [--gap-grace <seconds>] [--raw-wall-clock] [--json]

    Replays a JSONL adaptive-refresh trace against one or more refresh-timing policies and prints
    per-policy metrics over automatically segmented observed time. Simulated advances are
    counterfactual policy events; recorded live schedule evaluations are audited separately.

    Policies:
      adaptive       Plain production Adaptive policy. Uses menu opens only.
      adaptive-activity  Agent-aware Adaptive policy. Also uses local coding-activity fields.
      fixed-2m       Fixed 2 minute cadence. Unaffected by menu-open interactions.
      fixed-5m       Fixed 5 minute cadence.
      fixed-15m      Fixed 15 minute cadence.
      fixed-30m      Fixed 30 minute cadence.
      manual         Never refreshes (degenerate floor).

    Defaults to comparing all seven policies when --policy is omitted.

    Options:
      --policy <name>   Restrict to one listed policy; repeat to compare a specific subset.
      --gap-grace <s>   Split legacy gaps this many seconds after the last timer deadline (default 300).
      --raw-wall-clock  Disable gap segmentation; useful only for auditing the old behavior.
      --json            Print a machine-readable report including replay, activity, and audit data.
      -h, --help        Print this help text.
    """
}

AdaptiveReplayCLI.main()
