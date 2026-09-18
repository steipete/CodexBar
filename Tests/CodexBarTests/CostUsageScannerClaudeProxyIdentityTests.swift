import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerClaudeProxyIdentityTests {
    enum Placement: CaseIterable, Sendable {
        case sameFile
        case append
        case separateFiles
    }

    enum CopyPriority: CaseIterable, Sendable {
        case nonSidechain
        case parent
        case path
    }

    struct Identity: Sendable {
        var session: String? = "session"
        var message: String? = "response"
        var request: String?
    }

    struct DistinctRows: Sendable, CustomStringConvertible {
        let description: String
        let first: Identity
        let second: Identity

        static let cases: [Self] = [
            Self(
                description: "request and session key namespaces",
                first: Identity(session: "other", message: "session-a", request: "response-b"),
                second: Identity(session: "session-a", message: "response-b")),
            Self(
                description: "delimiters inside fallback identifiers",
                first: Identity(session: "session:a", message: "response"),
                second: Identity(session: "session", message: "a:response")),
            Self(
                description: "delimiters inside explicit request identifiers",
                first: Identity(message: "response:a", request: "request"),
                second: Identity(message: "response", request: "a:request")),
            Self(
                description: "different sessions",
                first: Identity(session: "session-a"),
                second: Identity(session: "session-b")),
            Self(
                description: "different messages",
                first: Identity(message: "response-a"),
                second: Identity(message: "response-b")),
            Self(
                description: "different explicit requests",
                first: Identity(request: "request-a"),
                second: Identity(request: "request-b")),
            Self(
                description: "missing versus present request identifier",
                first: Identity(),
                second: Identity(request: "request")),
            Self(
                description: "session identifiers remain exact",
                first: Identity(),
                second: Identity(session: " session ")),
            Self(
                description: "message identifiers remain exact",
                first: Identity(),
                second: Identity(message: " response ")),
            Self(
                description: "missing session identifiers",
                first: Identity(session: nil),
                second: Identity(session: nil)),
            Self(
                description: "empty session identifiers",
                first: Identity(session: ""),
                second: Identity(session: "")),
            Self(
                description: "whitespace session identifiers",
                first: Identity(session: " \n\t"),
                second: Identity(session: " \n\t")),
            Self(
                description: "missing message identifiers",
                first: Identity(message: nil),
                second: Identity(message: nil)),
            Self(
                description: "empty message identifiers",
                first: Identity(message: ""),
                second: Identity(message: "")),
            Self(
                description: "whitespace message identifiers",
                first: Identity(message: " \n\t"),
                second: Identity(message: " \n\t")),
        ]
    }

    @Test(arguments: DistinctRows.cases, Placement.allCases)
    func `claude retains usage without an exact shared identity`(
        rows: DistinctRows,
        placement: Placement) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let first = self.event(env: env, day: day, identity: rows.first, input: 10)
        let second = self.event(env: env, day: day, identity: rows.second, input: 20)
        let options = self.options(env: env)

        switch placement {
        case .sameFile:
            _ = try env.writeClaudeProjectFile(
                relativePath: "project-a/first.jsonl",
                contents: env.jsonl([first, second]))
        case .append:
            let file = try env.writeClaudeProjectFile(
                relativePath: "project-a/first.jsonl",
                contents: env.jsonl([first]))
            #expect(self.load(day: day, options: options).summary?.totalTokens == 11)
            try self.append(Data(env.jsonl([second]).utf8), to: file)
        case .separateFiles:
            _ = try env.writeClaudeProjectFile(
                relativePath: "project-a/first.jsonl", contents: env.jsonl([first]))
            _ = try env.writeClaudeProjectFile(
                relativePath: "project-b/second.jsonl", contents: env.jsonl([second]))
        }

        let report = self.load(day: day, options: options)
        #expect(report.summary?.totalInputTokens == 30)
        #expect(report.summary?.totalOutputTokens == 2)
        #expect(report.summary?.totalTokens == 32)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.000120) < 0.000000001)
    }

    @Test(arguments: ["request", "", " \t"])
    func `explicit request identity remains independent of the session`(request: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([
                self.event(
                    env: env,
                    day: day,
                    identity: Identity(session: "session-a", request: request),
                    input: 10),
                self.event(
                    env: env,
                    day: day,
                    identity: Identity(session: "session-b", request: request),
                    input: 20),
            ]))

        let report = self.load(day: day, options: self.options(env: env))
        #expect(report.summary?.totalInputTokens == 20)
        #expect(report.summary?.totalTokens == 21)
    }

    @Test(arguments: CopyPriority.allCases)
    func `proxy copies preserve the existing source preference`(priority: CopyPriority) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        var preferred = self.event(env: env, day: day, identity: Identity(), input: 10)
        var other = self.event(
            env: env, day: day.addingTimeInterval(1), identity: Identity(), input: 999)
        preferred["isSidechain"] = priority != .nonSidechain
        other["isSidechain"] = true

        let preferredPath: String
        let otherPath: String
        switch priority {
        case .nonSidechain:
            preferredPath = "project/session/subagents/z-preferred.jsonl"
            otherPath = "project/session.jsonl"
        case .parent:
            preferredPath = "project/session.jsonl"
            otherPath = "project/session/subagents/a-other.jsonl"
        case .path:
            preferredPath = "project/session/subagents/a-preferred.jsonl"
            otherPath = "project/session/subagents/z-other.jsonl"
        }
        _ = try env.writeClaudeProjectFile(relativePath: preferredPath, contents: env.jsonl([preferred]))
        _ = try env.writeClaudeProjectFile(relativePath: otherPath, contents: env.jsonl([other]))

        let report = self.load(day: day, options: self.options(env: env))
        #expect(report.summary?.totalInputTokens == 10)
        #expect(report.summary?.totalTokens == 11)
    }

    @Test
    func `proxy row ordering is independent of transcript encounter order`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let events = [
            self.event(env: env, day: day, identity: Identity(session: "b"), input: 10),
            self.event(env: env, day: day, identity: Identity(request: "request-b"), input: 20),
            self.event(env: env, day: day, identity: Identity(session: "a"), input: 30),
            self.event(env: env, day: day, identity: Identity(request: "request-a"), input: 40),
        ]
        let first = try env.writeClaudeProjectFile(
            relativePath: "project/first.jsonl", contents: env.jsonl(events))
        let reversed = try env.writeClaudeProjectFile(
            relativePath: "project/reversed.jsonl", contents: env.jsonl(Array(events.reversed())))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let forwardRows = CostUsageScanner.parseClaudeFile(
            fileURL: first, range: range, providerFilter: .all, modelsDevCacheRoot: env.cacheRoot).rows
        let reversedRows = CostUsageScanner.parseClaudeFile(
            fileURL: reversed, range: range, providerFilter: .all, modelsDevCacheRoot: env.cacheRoot).rows
        #expect(forwardRows.count == 4)
        #expect(forwardRows == reversedRows)
    }

    @Test
    func `incomplete proxy append survives a restart before completion`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let initial = self.event(env: env, day: day, identity: Identity(), input: 50, output: 7)
        let complete = self.event(env: env, day: day, identity: Identity(), input: 50, output: 19)
        let file = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl", contents: env.jsonl([initial]))
        let options = self.options(env: env)
        let initialReport = self.load(day: day, options: options)
        #expect(initialReport.summary?.totalTokens == 57)

        let appended = try Data(env.jsonl([complete]).utf8)
        let split = appended.count / 2
        try self.append(appended.prefix(split), to: file)
        let incompleteReport = self.load(day: day, options: options)
        #expect(incompleteReport.data == initialReport.data)
        #expect(incompleteReport.summary == initialReport.summary)

        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let restartedReport = self.load(day: day, options: options)
        #expect(restartedReport.data == initialReport.data)
        #expect(restartedReport.summary == initialReport.summary)

        try self.append(appended.suffix(from: split), to: file)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let completedReport = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            self.load(day: day, options: options)
        }
        #expect(recorder.snapshot().incrementalTranscriptParses == 1)
        #expect(completedReport.summary?.totalInputTokens == 50)
        #expect(completedReport.summary?.totalOutputTokens == 19)
        #expect(completedReport.summary?.totalTokens == 69)
        #expect(try abs(#require(completedReport.summary?.totalCostUSD) - 0.000435) < 0.000000001)

        var forced = options
        forced.forceRescan = true
        let rebuiltReport = self.load(day: day, options: forced)
        #expect(rebuiltReport.data == completedReport.data)
        #expect(rebuiltReport.summary == completedReport.summary)
    }

    @Test
    func `preliminary proxy estimates stay unknown beside recorded usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let pending = self.proxyUsageEvent(env: env, day: day, complete: false)
        let file = try env.writeClaudeProjectFile(
            relativePath: "project/session.jsonl", contents: env.jsonl([pending]))
        let options = self.options(env: env)
        let unknown = self.load(day: day, options: options)
        #expect(unknown.summary?.totalCostUSD == nil)
        #expect(unknown.summary?.totalTokens == nil)
        #expect(unknown.data.first?.incompleteRequestCount == 1)
        #expect(unknown.data.first?.modelBreakdowns?.first?.totalTokens == nil)

        // Legacy records without stop_reason are still valid, including zero output.
        let legacy = self.event(env: env, day: day, identity: Identity(message: "legacy"), input: 100, output: 0)
        try self.append(Data(env.jsonl([legacy]).utf8), to: file)
        let mixed = self.load(day: day, options: options)
        #expect(mixed.summary?.totalTokens == 100)
        #expect(try abs(#require(mixed.summary?.totalCostUSD) - 0.0003) < 0.000000001)
        #expect(mixed.data.first?.incompleteRequestCount == 1)
        let snapshot = CostUsageFetcher.tokenSnapshot(from: mixed, now: day)
        #expect(snapshot.summary(forLastDays: 1).incompleteRequestCount == 1)

        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(self.load(day: day, options: options).data == mixed.data)
    }

    @Test(arguments: Placement.allCases, [false, true])
    func `completed proxy usage wins over an early estimate in either order`(
        placement: Placement, reverse: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let first = self.proxyUsageEvent(env: env, day: day, complete: reverse)
        let second = self.proxyUsageEvent(env: env, day: day, complete: !reverse)
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(#"""
        {"openai":{"models":{"gpt-5.4":{"id":"gpt-5.4","cost":{"input":2.5,"output":15,"cache_read":0.25}}}}}
        """#.utf8))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let options = self.options(env: env)
        switch placement {
        case .sameFile:
            _ = try env.writeClaudeProjectFile(
                relativePath: "project/session.jsonl",
                contents: env.jsonl([first, second]))
        case .append:
            let file = try env.writeClaudeProjectFile(
                relativePath: "project/session.jsonl",
                contents: env.jsonl([first]))
            _ = self.load(day: day, options: options)
            try self.append(Data(env.jsonl([second]).utf8), to: file)
        case .separateFiles:
            _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl([first]))
            _ = try env.writeClaudeProjectFile(
                relativePath: "project/session/subagents/agent.jsonl", contents: env.jsonl([second]))
        }
        let report = self.load(day: day, options: options)
        #expect(report.summary?.totalTokens == 1860)
        #expect(report.summary?.cacheReadTokens == 1664)
        #expect(report.data.first?.incompleteRequestCount == 0)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.0009685) < 0.000000001)
    }

    private func proxyUsageEvent(env: CostUsageTestEnvironment, day: Date, complete: Bool) -> [String: Any] {
        [
            "type": "assistant", "timestamp": env.isoString(for: day), "sessionId": "session",
            "message": [
                "id": "response", "model": "gpt-5.4",
                "stop_reason": complete ? "end_turn" : NSNull(),
                "usage": complete
                    ? ["input_tokens": 191, "cache_read_input_tokens": 1664, "output_tokens": 5]
                    : ["input_tokens": 1612, "output_tokens": 0],
            ],
        ]
    }

    private func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func load(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .claude, since: day, until: day, now: day, options: options)
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func event(
        env: CostUsageTestEnvironment,
        day: Date,
        identity: Identity,
        input: Int,
        output: Int = 1) -> [String: Any]
    {
        var message: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "usage": ["input_tokens": input, "output_tokens": output],
        ]
        message["id"] = identity.message
        var event: [String: Any] = [
            "type": "assistant", "timestamp": env.isoString(for: day), "message": message,
        ]
        event["sessionId"] = identity.session
        event["requestId"] = identity.request
        return event
    }
}
