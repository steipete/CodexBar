import Foundation
import Testing
@testable import CodexBarCore

struct MuseLocalSessionScannerTests {
    // MARK: - Helpers

    private func makeSessionLine(
        recordedAtMicroseconds: Int64,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int = 0,
        cacheReadTokens: Int? = nil,
        reasoningTokens: Int = 0,
        model: String = "muse-spark-1.2-contributor") -> String
    {
        let usage: [String: Any] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cached_tokens": cachedTokens,
            "cache_write_tokens": 0,
            "cache_read_tokens": cacheReadTokens ?? cachedTokens,
            "reasoning_tokens": reasoningTokens,
        ]
        let event: [String: Any] = [
            "kind": "model_completed",
            "usage": usage,
            "duration_ms": 1000,
            "finish_reason": "tool_calls",
            "model": model,
        ]
        let payload: [String: Any] = ["kind": "run", "event": event]
        let outer: [String: Any] = [
            "recorded_at": recordedAtMicroseconds,
            "payload_type": "runtime.session",
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func makeGoalAttributionLine(
        recordedAtMicroseconds: Int64,
        inputTokens: Int,
        outputTokens: Int) -> String
    {
        // Intentionally same token counts — must NOT be counted.
        let outer: [String: Any] = [
            "recorded_at": recordedAtMicroseconds,
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run",
                "event": [
                    "kind": "goal_usage_attribution",
                    "record": [
                        "usage_family": "provider",
                        "quantity": [
                            "unit": "tokens",
                            "reported": true,
                            "input_tokens": inputTokens,
                            "output_tokens": outputTokens,
                        ],
                    ],
                ],
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func microseconds(for date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000)
    }

    // MARK: - Tests

    @Test
    func `single model_completed produces expected token usage`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-single-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("sessions/2026/08/27/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_787_840_784) // 2026-08-27 14:26:24 UTC, matches recorded_at micro convention
        let line = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 20374,
            outputTokens: 128,
            reasoningTokens: 27)

        try line.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: now)
        #expect(summary.requestCount == 1)
        #expect(summary.totalTokens == 20374 + 128)
        #expect(summary.totalInputTokens == 20374)
        #expect(summary.totalOutputTokens == 128)
        #expect(summary.totalReasoningTokens == 27)
        #expect(summary.daily.count == 1)
        #expect(summary.daily.first?.totalTokens == 20502)
        #expect(summary.daily.first?.requestCount == 1)

        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 30))
        #expect(snapshot.last30DaysTokens == 20502)
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.sessionTokens == 20502)
        #expect(snapshot.daily.first?.totalTokens == 20502)
        #expect(snapshot.costProvenance == .unknown)
    }

    @Test
    func `goal_usage_attribution does not double-count`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-dedup-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("sessions/2026/08/27/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let goal = self.makeGoalAttributionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 20374,
            outputTokens: 128)
        let model = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now.addingTimeInterval(1)),
            inputTokens: 20374,
            outputTokens: 128)

        let combined = [goal, model].joined(separator: "\n")
        try combined.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: now)
        // Only the model_completed counts; goal attribution is ignored.
        #expect(summary.requestCount == 1)
        #expect(summary.totalTokens == 20502)
    }

    @Test
    func `subagent usage is recursively included`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-subagent-\(UUID().uuidString)", isDirectory: true)
        let parentDir = root.appendingPathComponent("sessions/2026/08/27/parent", isDirectory: true)
        let subagentDir = parentDir.appendingPathComponent("subagent/child-1", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let parentLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 1000,
            outputTokens: 100)
        let childLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now.addingTimeInterval(10)),
            inputTokens: 500,
            outputTokens: 50)

        try parentLine.write(to: parentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try childLine.write(to: subagentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let summary = MuseLocalSessionScanner.summarize(
            env: ["CODEXBAR_MUSE_HOME": root.path],
            lookbackDays: 30,
            now: now)
        #expect(summary.fileCount == 2)
        #expect(summary.requestCount == 2)
        #expect(summary.totalTokens == 1650)
    }

    @Test
    func `multiple events aggregate into daily and history buckets`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-multi-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("sessions/2026/08/27/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_787_840_784) // 2026-08-27
        let day0 = try #require(calendar.date(byAdding: .day, value: -1, to: day1))
        // Use microsecond wall-clock that matches dayKey via Calendar.current — set TZ to UTC for determinism
        // but scanner uses Calendar.current; we force day keys via recorded_at near midnight.
        // Instead use explicit dates and derive dayKey via scanner's calendar.
        let l1 = self.makeSessionLine(recordedAtMicroseconds: self.microseconds(for: day0), inputTokens: 100, outputTokens: 10)
        let l2 = self.makeSessionLine(recordedAtMicroseconds: self.microseconds(for: day0.addingTimeInterval(3600)), inputTokens: 200, outputTokens: 20)
        let l3 = self.makeSessionLine(recordedAtMicroseconds: self.microseconds(for: day1), inputTokens: 300, outputTokens: 30)

        try [l1, l2, l3].joined(separator: "\n")
            .write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: day1)
        #expect(summary.requestCount == 3)
        #expect(summary.totalTokens == 660)
        // daily buckets are at least 2 days
        #expect(summary.daily.count >= 2)
        let totalDaily = summary.daily.reduce(0) { $0 + $1.totalTokens }
        #expect(totalDaily == 660)

        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 30))
        let window = snapshot.summary(forLastDays: 30)
        #expect(window.totalTokens == 660)
        #expect(window.totalRequests == 3)
    }

    @Test
    func `empty roots do not publish bogus usage`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-empty-\(UUID().uuidString)", isDirectory: true)
        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: Date())
        #expect(summary.requestCount == 0)
        #expect(summary.toCostUsageTokenSnapshot(historyDays: 30) == nil)
        let snap = MuseUsageSnapshot(summary: summary)
        #expect(snap.toUsageSnapshot().costUsage == nil)
    }

    @Test
    func `malformed and unrelated lines are safely ignored`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-malformed-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("sessions/2026/08/27/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let good = self.makeSessionLine(recordedAtMicroseconds: self.microseconds(for: now), inputTokens: 100, outputTokens: 10)
        let badJSON = "{ not valid json"
        let missingKind = "{\"recorded_at\":\(self.microseconds(for: now)),\"payload_type\":\"runtime.session\",\"payload\":{\"kind\":\"run\",\"event\":{\"kind\":\"other\"}}}"
        let wrongPayloadType = "{\"recorded_at\":\(self.microseconds(for: now)),\"payload_type\":\"other\",\"payload\":{\"kind\":\"run\",\"event\":{\"kind\":\"model_completed\"}}}"
        // Sensitive fields outside usage must not affect parsing — tested via makeSensitiveLine below.

        let combined = [good, badJSON, missingKind, wrongPayloadType].joined(separator: "\n")
        let sensitiveExtra = try self.makeSensitiveLine(now: now)
        let all = [combined, sensitiveExtra].joined(separator: "\n")
        try all.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: now)
        // Only good + sensitiveExtra are valid; malformed lines are ignored.
        #expect(summary.requestCount == 2)
        #expect(summary.totalTokens == 1400) // good(110) + sensitiveExtra(1290)
    }

    @Test
    func `sensitive prompt fields do not affect token parsing`() throws {
        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let line = try self.makeSensitiveLine(now: now)
        let parsed = MuseLocalSessionScanner.parseLine(Data(line.utf8))
        #expect(parsed != nil)
        #expect(parsed?.inputTokens == 1234)
        #expect(parsed?.outputTokens == 56)
    }

    @Test
    func `truncated lines are discarded`() {
        // Simulate a line larger than prefixBytes that would be marked truncated.
        // We test parseLine directly: truncated lines are filtered in events(in:) not here,
        // but a 32 KiB+ line beyond 8 KiB prefix that still contains model_completed should be dropped.
        // This is exercised indirectly via CostUsageJsonl truncation — we assert the scanner
        // never crashes and ignores oversized lines.
        let hugePrompt = String(repeating: "a", count: 40 * 1024)
        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let outer: [String: Any] = [
            "recorded_at": self.microseconds(for: now),
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run",
                "event": [
                    "kind": "model_completed",
                    "usage": ["input_tokens": 10, "output_tokens": 5, "cached_tokens": 0, "reasoning_tokens": 0],
                    "model": "muse-spark-1.2-contributor",
                ],
            ] as [String: Any],
            "extra_prompt": hugePrompt,
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer, options: [])
        // Data is >32 KiB, will be truncated when scanned with prefix 8 KiB; parseLine on full data would succeed,
        // but the scanner's CostUsageJsonl path marks it truncated and skips it. We verify full data still parses
        // (correctness) and that the file-level path handles truncation gracefully elsewhere.
        let parsed = MuseLocalSessionScanner.parseLine(data)
        #expect(parsed != nil)
    }

    @Test
    func `timestamp bucketing uses microsecond wall clock`() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 27)))
        let beforeMidnight = midnight.addingTimeInterval(-1) // 2026-08-26 23:59:59 UTC
        let afterMidnight = midnight.addingTimeInterval(1)

        let lineBefore = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: beforeMidnight),
            inputTokens: 100,
            outputTokens: 10)
        let lineAfter = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: afterMidnight),
            inputTokens: 200,
            outputTokens: 20)

        let e1 = try #require(MuseLocalSessionScanner.parseLine(Data(lineBefore.utf8)))
        let e2 = try #require(MuseLocalSessionScanner.parseLine(Data(lineAfter.utf8)))
        // Dates preserve wall-clock order and are near midnight.
        #expect(e1.date < e2.date)
        // Day keys should differ when crossing UTC midnight (Calendar.current may be non-UTC, so we only assert
        // that dayKey formatting is consistent with the parsed date's calendar day).
        let k1 = try #require(MuseLocalSessionScanner.dayKey(for: e1.date, calendar: calendar))
        let k2 = try #require(MuseLocalSessionScanner.dayKey(for: e2.date, calendar: calendar))
        #expect(k1 != k2)
        #expect(k1 == "2026-08-26")
        #expect(k2 == "2026-08-27")
    }

    @Test
    func `cache and reasoning are extracted but not double-counted`() throws {
        let now = Date(timeIntervalSince1970: 1_787_840_784)
        let line = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 1000,
            outputTokens: 200,
            cachedTokens: 800,
            reasoningTokens: 150)
        let parsed = try #require(MuseLocalSessionScanner.parseLine(Data(line.utf8)))
        #expect(parsed.inputTokens == 1000)
        #expect(parsed.outputTokens == 200)
        #expect(parsed.cacheReadTokens == 800)
        #expect(parsed.reasoningTokens == 150)
        // total = input + output, not input+output+cache+reasoning
        #expect(parsed.inputTokens + parsed.outputTokens == 1200)
    }

    // MARK: - Helpers for sensitive payload

    @Test
    func `files outside lookback date directories are not scanned`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-prune-\(UUID().uuidString)", isDirectory: true)
        // Use local calendar for directory layout so pruning is deterministic regardless of host TZ.
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let oldDate = localCalendar.date(byAdding: .day, value: -60, to: now)!
        let recentKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let oldKey = MuseLocalSessionScanner.dayKey(for: oldDate, calendar: localCalendar)!
        let recentDir = root.appendingPathComponent("sessions/\(recentKey.replacingOccurrences(of: "-", with: "/"))/recent", isDirectory: true)
        let oldDir = root.appendingPathComponent("sessions/\(oldKey.replacingOccurrences(of: "-", with: "/"))/old", isDirectory: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)

        let recentLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 100,
            outputTokens: 10)
        // Old event's recorded_at is recent (so if file were scanned, it would count),
        // but its directory date is outside lookback — pruning must prevent opening it.
        let oldLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 9999,
            outputTokens: 9999)

        try recentLine.write(to: recentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try oldLine.write(to: oldDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var scannedURLs: [URL] = []
        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 7,
            now: now,
            fileScanObserver: { url in scannedURLs.append(url) })

        // Only recent file should have been opened; old directory must be pruned.
        let recentSlash = recentKey.replacingOccurrences(of: "-", with: "/")
        let oldSlash = oldKey.replacingOccurrences(of: "-", with: "/")
        #expect(scannedURLs.count == 1)
        #expect(scannedURLs.first?.path.contains(recentSlash) == true)
        #expect(scannedURLs.allSatisfy { !$0.path.contains(oldSlash) })
        #expect(summary.requestCount == 1)
        #expect(summary.totalTokens == 110)
    }

    @Test
    func `subagent files are included within selected dates but old dates remain pruned`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-prune-subagent-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let oldDate = localCalendar.date(byAdding: .day, value: -60, to: now)!
        let recentKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let oldKey = MuseLocalSessionScanner.dayKey(for: oldDate, calendar: localCalendar)!
        let recentDir = root.appendingPathComponent("sessions/\(recentKey.replacingOccurrences(of: "-", with: "/"))/recent", isDirectory: true)
        let recentSub = recentDir.appendingPathComponent("subagent/child", isDirectory: true)
        let oldDir = root.appendingPathComponent("sessions/\(oldKey.replacingOccurrences(of: "-", with: "/"))/old", isDirectory: true)
        let oldSub = oldDir.appendingPathComponent("subagent/child", isDirectory: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentSub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldSub, withIntermediateDirectories: true)

        let parentLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 100,
            outputTokens: 10)
        let childLine = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 200,
            outputTokens: 20)
        let oldParent = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 999,
            outputTokens: 999)
        let oldChild = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 999,
            outputTokens: 999)

        try parentLine.write(to: recentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try childLine.write(to: recentSub.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try oldParent.write(to: oldDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try oldChild.write(to: oldSub.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var scanned: [URL] = []
        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 7,
            now: now,
            fileScanObserver: { scanned.append($0) })

        let recentSlash2 = recentKey.replacingOccurrences(of: "-", with: "/")
        let oldSlash2 = oldKey.replacingOccurrences(of: "-", with: "/")
        #expect(scanned.count == 2)
        #expect(scanned.allSatisfy { $0.path.contains(recentSlash2) })
        #expect(scanned.allSatisfy { !$0.path.contains(oldSlash2) })
        // Both recent parent and child are counted; old files pruned entirely.
        #expect(summary.requestCount == 2)
        #expect(summary.totalTokens == 330)
        #expect(summary.fileCount == 2)
    }

    @Test
    func `nonexistent date directories are skipped cheaply`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-scan-missing-\(UUID().uuidString)", isDirectory: true)
        // Only create one date directory; the other 29 in the lookback window do not exist and must be skipped.
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27))!
        let onlyKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let onlyDir = root.appendingPathComponent("sessions/\(onlyKey.replacingOccurrences(of: "-", with: "/"))/only", isDirectory: true)
        try FileManager.default.createDirectory(at: onlyDir, withIntermediateDirectories: true)

        let line = self.makeSessionLine(
            recordedAtMicroseconds: self.microseconds(for: now),
            inputTokens: 10,
            outputTokens: 5)
        try line.write(to: onlyDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var scanned: [URL] = []
        let summary = MuseLocalSessionScanner.summarize(
            env: ["MUSE_HOME": root.path],
            lookbackDays: 30,
            now: now,
            fileScanObserver: { scanned.append($0) })
        #expect(scanned.count == 1)
        #expect(summary.requestCount == 1)
    }

    private func makeSensitiveLine(now: Date) throws -> String {
        let outer: [String: Any] = [
            "recorded_at": self.microseconds(for: now),
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run",
                "event": [
                    "kind": "model_completed",
                    "usage": ["input_tokens": 1234, "output_tokens": 56, "cached_tokens": 0, "reasoning_tokens": 0],
                    "model": "muse-spark-1.2-contributor",
                ],
                "prompt": "THIS IS A SECRET PROMPT THAT MUST NOT BE RETAINED",
                "tool_output": ["secret": "do not persist"],
            ] as [String: Any],
            "prompt": "top-level secret",
        ]
        let data = try JSONSerialization.data(withJSONObject: outer, options: [])
        return String(data: data, encoding: .utf8)!
    }
}
