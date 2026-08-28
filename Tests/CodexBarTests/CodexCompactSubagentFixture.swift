import Foundation

enum CodexCompactSubagentFixture {
    typealias Usage = (input: Int, cached: Int, output: Int)

    struct Child {
        let sessionID: String
        let parentID: String
        let leafModel: String
        let prefix: Usage
        let suffix: Usage
        let preBoundaryLast: Usage?
    }

    static func parentContents(
        env: CostUsageTestEnvironment,
        day: Date,
        sessionID: String,
        model: String,
        totals: Usage) throws -> String
    {
        try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day.addingTimeInterval(-2)),
                "payload": ["id": sessionID],
            ],
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(-2)),
                model: model),
            self.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(-1)),
                model: model,
                total: totals,
                last: totals),
        ])
    }

    static func childContents(
        env: CostUsageTestEnvironment,
        day: Date,
        fixture: Child) throws -> String
    {
        let forkTimestamp = env.isoString(for: day)
        var lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": forkTimestamp,
                "payload": [
                    "id": fixture.sessionID,
                    "forked_from_id": fixture.parentID,
                    "timestamp": forkTimestamp,
                    "source": [
                        "subagent": [
                            "thread_spawn": ["parent_thread_id": fixture.parentID],
                        ],
                    ],
                ],
            ],
            self.tokenCountWithoutModel(
                timestamp: env.isoString(for: day.addingTimeInterval(0.1)),
                total: fixture.prefix,
                last: fixture.prefix),
        ]
        if let preBoundaryLast = fixture.preBoundaryLast {
            lines.append(self.tokenCountWithoutModel(
                timestamp: env.isoString(for: day.addingTimeInterval(0.2)),
                last: preBoundaryLast))
        }
        lines.append(contentsOf: [
            self.turnContext(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: fixture.leafModel),
            [
                "type": "inter_agent_communication_metadata",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": ["trigger_turn": true],
            ],
            self.tokenCountWithoutModel(
                timestamp: env.isoString(for: day.addingTimeInterval(2)),
                total: (
                    input: fixture.prefix.input + fixture.suffix.input,
                    cached: fixture.prefix.cached + fixture.suffix.cached,
                    output: fixture.prefix.output + fixture.suffix.output),
                last: fixture.suffix),
        ])
        return try env.jsonl(lines)
    }

    static func tokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = ["model": model]
        if let total {
            info["total_token_usage"] = self.usagePayload(total)
        }
        if let last {
            info["last_token_usage"] = self.usagePayload(last)
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }

    private static func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": model],
        ]
    }

    private static func tokenCountWithoutModel(
        timestamp: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = [:]
        if let total {
            info["total_token_usage"] = self.usagePayload(total)
        }
        if let last {
            info["last_token_usage"] = self.usagePayload(last)
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }

    private static func usagePayload(_ usage: Usage) -> [String: Any] {
        [
            "input_tokens": usage.input,
            "cached_input_tokens": usage.cached,
            "output_tokens": usage.output,
        ]
    }
}
