import Foundation
@testable import CodexBarCore

/// Shared synthetic native turn used by timing and completion-day tests.
enum CostUsageTurnPerformanceFixture {
    static func turn(
        env: CostUsageTestEnvironment,
        day: Date,
        session: String,
        turn: Int,
        requests: Int) throws -> String
    {
        let turnID = "turn-\(turn)"
        let start = day.addingTimeInterval(Double(turn * 30))
        var objects: [[String: Any]] = [[
            "type": "event_msg", "timestamp": env.isoString(for: start),
            "payload": ["type": "task_started", "turn_id": turnID],
        ]]
        for request in 0..<requests {
            let count = turn * requests + request + 1
            objects.append([
                "type": "token_usage_record",
                "timestamp": env.isoString(for: start.addingTimeInterval(Double(request))),
                "payload": [
                    "thread_id": session,
                    "session_id": session,
                    "turn_id": turnID,
                    "response_id": "\(session)-\(turn)-\(request)",
                    "model": "gpt-5.4",
                    "usage": Self.usage(1),
                    "thread_token_usage": Self.usage(count),
                    "turn_token_usage": Self.usage(request + 1),
                ],
            ])
        }
        objects.append([
            "type": "event_msg", "timestamp": env.isoString(for: start.addingTimeInterval(10)),
            "payload": [
                "type": "task_complete",
                "turn_id": turnID,
                "started_at": Int(start.timeIntervalSince1970),
                "completed_at": Int(start.timeIntervalSince1970) + 10,
                "duration_ms": 10000,
                "time_to_first_token_ms": 200,
                "error": NSNull(),
            ],
        ])
        return try env.jsonl(objects)
    }

    private static func usage(_ count: Int) -> [String: Int] {
        [
            "input_tokens": count * 100,
            "output_tokens": count * 10,
            "cached_input_tokens": 0,
            "reasoning_output_tokens": count * 5,
        ]
    }
}
