import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeSessionProjectTests {
    private static let model = "claude-sonnet-4-5"
    private static let alpha = "/Users/test/projects/alpha"
    private static let beta = "/Users/test/projects/beta"

    @Test
    func `sessions and projects partition the native daily total`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/session-one.jsonl", [
            self.line(env, day, session: "session-one", message: "m1", cwd: Self.alpha),
            self.line(env, day, session: "session-one", message: "m2", cwd: Self.alpha),
        ])
        try self.write(env, "alpha/session-one/subagents/agent-a.jsonl", [
            self.line(env, day, session: "session-one", message: "m3", cwd: Self.alpha, sidechain: true),
        ])
        try self.write(env, "alpha/session-two.jsonl", [
            self.line(env, day, session: "session-two", message: "m4", cwd: Self.alpha),
        ])
        try self.write(env, "beta/session-three.jsonl", [
            self.line(env, day, session: "session-three", message: "m5", cwd: Self.beta, input: 200, output: 20),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        #expect(projections.daily.summary?.totalTokens == 660)
        let sessions = Dictionary(uniqueKeysWithValues: projections.sessions.map { ($0.sessionID, $0) })
        #expect(Set(sessions.keys) == ["session-one", "session-two", "session-three"])
        let one = try #require(sessions["session-one"])
        #expect(one.totalTokens == 330)
        #expect(one.requestCount == 3)
        #expect(one.inputTokens == 300)
        #expect(one.cachedInputTokens == 0)
        #expect(one.outputTokens == 30)
        #expect(one.projectPath == Self.alpha)
        #expect(one.projectName == "alpha")
        #expect(one.title == nil)
        #expect(one.modelBreakdowns.map(\.modelName) == [Self.model])
        #expect(sessions["session-three"]?.projectPath == Self.beta)
        #expect(projections.projects.map(\.name) == ["alpha", "beta"])
        #expect(projections.projects.map(\.path) == [Self.alpha, Self.beta])
        #expect(projections.projects.map(\.totalTokens) == [440, 220])
        #expect(projections.projects.first?.sources.map(\.path) == [Self.alpha])
    }

    @Test
    func `copied response across resumed transcripts counts once with one owner`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/session-original.jsonl", [
            self.line(env, day, session: "session-original", message: "shared", cwd: Self.alpha),
            self.line(env, day, session: "session-original", message: "m2", cwd: Self.alpha),
        ])
        try self.write(env, "alpha/session-resumed.jsonl", [
            self.line(env, day, session: "session-resumed", message: "shared", cwd: Self.alpha),
            self.line(env, day, session: "session-resumed", message: "m3", cwd: Self.alpha),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        #expect(projections.daily.summary?.totalTokens == 330)
        #expect(projections.sessions.count == 2)
        #expect(projections.sessions.compactMap(\.requestCount).reduce(0, +) == 3)
        #expect(projections.sessions.compactMap(\.totalTokens).sorted() == [110, 220])
    }

    @Test
    func `sidechain and subagent copies yield ownership to the parent copy`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        // Both losing copies sort before the parent copy, so only the role rules can pick the parent.
        try self.write(env, "alpha/aa-agent/subagents/agent.jsonl", [
            self.line(env, day, session: "subagent-session", message: "shared", cwd: Self.alpha),
        ])
        try self.write(env, "alpha/ab-side.jsonl", [
            self.line(env, day, session: "sidechain-session", message: "shared", cwd: Self.alpha, sidechain: true),
        ])
        try self.write(env, "alpha/zz-parent.jsonl", [
            self.line(env, day, session: "parent-session", message: "shared", cwd: Self.alpha),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        #expect(projections.sessions.map(\.sessionID) == ["parent-session"])
        #expect(projections.sessions.first?.totalTokens == 110)
    }

    @Test
    func `rows without session id fall back to the subagent parent directory or the file stem`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/stem-session.jsonl", [
            self.line(env, day, session: nil, message: "m1", cwd: Self.alpha),
        ])
        try self.write(env, "alpha/dir-session/subagents/agent.jsonl", [
            self.line(env, day, session: nil, message: "m2", cwd: Self.beta),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        let projects = Dictionary(uniqueKeysWithValues: projections.sessions.map { ($0.sessionID, $0.projectPath) })
        #expect(projects == ["stem-session": Self.alpha, "dir-session": Self.beta])
    }

    @Test
    func `cwd-less winner still uses the session cwd from another copy`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        let audit: [String: Any] = [
            "type": "assistant", "timestamp": env.isoString(for: day),
            "session_id": "cowork-session", "request_id": "cowork-request",
            "message": [
                "id": "cowork-message",
                "model": Self.model,
                "usage": ["input_tokens": 100, "output_tokens": 10],
            ],
        ]
        // The embedded transcript holds an unfinished copy, so the complete cwd-less audit copy wins.
        let transcript: [String: Any] = [
            "type": "assistant", "timestamp": env.isoString(for: day),
            "sessionId": "cowork-session", "requestId": "cowork-request", "cwd": Self.alpha,
            "message": [
                "id": "cowork-message",
                "model": Self.model,
                "stop_reason": NSNull(),
                "usage": ["input_tokens": 100, "output_tokens": 0],
            ],
        ]
        _ = try env.writeClaudeDesktopLocalAgentFile(relativePath: "audit.jsonl", contents: env.jsonl([audit]))
        _ = try env.writeClaudeDesktopLocalAgentProjectFile(
            relativePath: "alpha/cowork-session.jsonl", contents: env.jsonl([transcript]))
        let roots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: .init(cacheRoot: env.cacheRoot), environment: [:], homeDirectory: env.root)

        let (projections, _) = try self.load(env, day, roots: roots)

        try self.expectPartition(projections)
        #expect(projections.daily.summary?.totalOutputTokens == 10)
        #expect(projections.sessions.map(\.sessionID) == ["cowork-session"])
        #expect(projections.sessions.first?.projectPath == Self.alpha)
        #expect(projections.projects.map(\.path) == [Self.alpha])
    }

    @Test
    func `transcripts without cwd land in the unknown project`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/no-cwd-session.jsonl", [
            self.line(env, day, session: "no-cwd-session", message: "m1", cwd: nil),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        #expect(projections.projects.map(\.name) == [CostUsageProjectBreakdown.unknownProjectName])
        #expect(projections.projects.first?.path == nil)
        #expect(projections.sessions.first?.projectPath == nil)
        #expect(projections.sessions.first?.projectName == nil)
    }

    @Test
    func `append keeps the first cwd and attributes new rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        let url = try self.write(env, "alpha/append-session.jsonl", [
            self.line(env, day, session: "append-session", message: "m1", cwd: Self.alpha),
        ])
        let (initial, _) = try self.load(env, day)
        #expect(initial.sessions.first?.totalTokens == 110)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            self.line(env, day, session: "append-session", message: "m2", cwd: Self.beta),
        ]).utf8))
        try handle.close()
        let (appended, work) = try self.load(env, day)

        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 1)
        try self.expectPartition(appended)
        #expect(appended.sessions.map(\.sessionID) == ["append-session"])
        #expect(appended.sessions.first?.totalTokens == 220)
        #expect(appended.projects.map(\.path) == [Self.alpha])
    }

    @Test
    func `rewritten transcript reparses and replaces project attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/rewrite-session.jsonl", [
            self.line(env, day, session: "rewrite-session", message: "m1", cwd: Self.alpha),
        ])
        let (initial, _) = try self.load(env, day)
        #expect(initial.projects.map(\.path) == [Self.alpha])

        // Atomic replacement publishes a new file identity, which forces a full parse.
        try self.write(env, "alpha/rewrite-session.jsonl", [
            self.line(env, day, session: "rewrite-session", message: "m1", cwd: Self.beta),
            self.line(env, day, session: "rewrite-session", message: "m2", cwd: Self.beta),
        ])
        let (rewritten, work) = try self.load(env, day)

        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        try self.expectPartition(rewritten)
        #expect(rewritten.projects.map(\.path) == [Self.beta])
        #expect(rewritten.sessions.first?.projectPath == Self.beta)
        #expect(rewritten.sessions.first?.totalTokens == 220)
    }

    @Test
    func `breakdowns reuse the memo and a persisted memo reloads cache without reparsing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try self.write(env, "alpha/memo-session.jsonl", [
            self.line(env, day, session: "memo-session", message: "m1", cwd: Self.alpha),
        ])
        let (first, firstWork) = try self.load(env, day)
        #expect(firstWork.transcriptParses == 1)

        let (warm, warmWork) = try self.load(env, day)
        #expect(warmWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(warm.sessions == first.sessions)
        #expect(warm.projects == first.projects)

        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (restarted, restartWork) = try self.load(env, day)
        #expect(restartWork.transcriptParses == 0)
        #expect(restartWork.cacheDecodes == 1)
        #expect(restarted.daily.data == first.daily.data)
        #expect(restarted.sessions == first.sessions)
        #expect(restarted.projects == first.projects)

        let (rewarmed, rewarmedWork) = try self.load(env, day)
        #expect(rewarmedWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(rewarmed.sessions == first.sessions)
    }

    @Test(arguments: [nil, .regular, .spendDashboard] as [CostUsageReportContext?])
    func `daily report is identical with and without breakdowns`(context: CostUsageReportContext?) throws {
        let dailyEnv = try CostUsageTestEnvironment()
        let breakdownEnv = try CostUsageTestEnvironment()
        defer {
            dailyEnv.cleanup()
            breakdownEnv.cleanup()
        }
        let day = try dailyEnv.makeLocalNoon(year: 2026, month: 3, day: 10)
        for env in [dailyEnv, breakdownEnv] {
            try self.write(env, "alpha/session-one.jsonl", [
                self.line(env, day, session: "session-one", message: "m1", cwd: Self.alpha),
                self.line(env, day.addingTimeInterval(-3600), session: "session-one", message: "m2", cwd: Self.alpha),
            ])
            try self.write(env, "beta/session-two.jsonl", [
                self.line(env, day, session: "session-two", message: "m3", cwd: Self.beta, input: 300, output: 7),
                self.line(env, day, session: "session-two", message: "m1", cwd: Self.beta),
            ])
        }

        let daily = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: self.options(dailyEnv),
            reportContext: context,
            checkCancellation: nil)
        let (projections, _) = try self.load(breakdownEnv, day, context: context)

        #expect(projections.daily.data == daily.data)
        #expect(projections.daily.summary == daily.summary)
        #expect(projections.daily.hourly == daily.hourly)
        #expect(projections.daily.quotaSlices == daily.quotaSlices)
        #expect(!projections.sessions.isEmpty)
    }

    @Test
    func `sessions outside the display window are omitted`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        let previousDay = try env.makeLocalNoon(year: 2026, month: 3, day: 9)
        try self.write(env, "alpha/today-session.jsonl", [
            self.line(env, day, session: "today-session", message: "m1", cwd: Self.alpha),
        ])
        // The scan keeps a one-day margin, so this row is parsed but outside the reported day.
        try self.write(env, "beta/yesterday-session.jsonl", [
            self.line(env, previousDay, session: "yesterday-session", message: "m2", cwd: Self.beta),
        ])

        let (projections, _) = try self.load(env, day)

        try self.expectPartition(projections)
        #expect(projections.sessions.map(\.sessionID) == ["today-session"])
        #expect(projections.projects.map(\.path) == [Self.alpha])
    }

    // MARK: - Fixtures

    private func line(
        _ env: CostUsageTestEnvironment,
        _ date: Date,
        session: String?,
        message: String,
        cwd: String?,
        input: Int = 100,
        output: Int = 10,
        sidechain: Bool = false) -> [String: Any]
    {
        var object: [String: Any] = [
            "type": "assistant",
            "timestamp": env.isoString(for: date),
            "requestId": "request-\(message)",
            "message": [
                "id": message,
                "model": Self.model,
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        if let session { object["sessionId"] = session }
        if let cwd { object["cwd"] = cwd }
        if sidechain { object["isSidechain"] = true }
        return object
    }

    @discardableResult
    private func write(
        _ env: CostUsageTestEnvironment,
        _ relativePath: String,
        _ lines: [[String: Any]]) throws -> URL
    {
        try env.writeClaudeProjectFile(relativePath: relativePath, contents: env.jsonl(lines))
    }

    private func options(_ env: CostUsageTestEnvironment, roots: [URL]? = nil) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: roots ?? [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 60
        return options
    }

    private func load(
        _ env: CostUsageTestEnvironment,
        _ day: Date,
        roots: [URL]? = nil,
        context: CostUsageReportContext? = nil) throws
        -> (ClaudeReportProjections, CostUsageScanner.ClaudeScanWorkMetrics)
    {
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let projections = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            try CostUsageScanner.loadClaudeReportProjectionsCancellable(
                since: day,
                until: day,
                now: day,
                options: self.options(env, roots: roots),
                reportContext: context,
                checkCancellation: nil)
        }
        return (projections, recorder.snapshot())
    }

    private func expectPartition(_ projections: ClaudeReportProjections) throws {
        let summary = try #require(projections.daily.summary)
        let totalTokens = try #require(summary.totalTokens)
        let totalCost = try #require(summary.totalCostUSD)
        #expect(projections.sessions.compactMap(\.totalTokens).reduce(0, +) == totalTokens)
        #expect(projections.projects.compactMap(\.totalTokens).reduce(0, +) == totalTokens)
        #expect(abs(projections.sessions.compactMap(\.costUSD).reduce(0, +) - totalCost) < 1e-9)
        #expect(abs(projections.projects.compactMap(\.totalCostUSD).reduce(0, +) - totalCost) < 1e-9)
    }
}
