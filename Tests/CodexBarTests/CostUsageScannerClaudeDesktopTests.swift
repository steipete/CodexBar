import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerClaudeDesktopTests {
    @Test
    func `Cowork audit usage shares native response deduplication`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 16)
        func assistant(session: String, output: Int) -> [String: Any] {
            [
                "type": "assistant", "timestamp": env.isoString(for: day), "session_id": session,
                "message": [
                    "id": "response-a", "model": "claude-test-model",
                    "usage": ["input_tokens": 10, "output_tokens": output],
                ],
            ]
        }
        let response = assistant(session: "cowork-a", output: 5)
        let audit = try env.writeClaudeDesktopLocalAgentFile(
            relativePath: "audit.jsonl",
            contents: env.jsonl([
                assistant(session: "cowork-a", output: 1), response,
                assistant(session: "cowork-b", output: 7),
                [
                    "type": "result",
                    "timestamp": env.isoString(for: day),
                    "usage": ["input_tokens": 999, "output_tokens": 999],
                ],
            ]))
        _ = try env.writeClaudeDesktopSharedProjectFile(
            relativePath: "mirror/session.jsonl", contents: env.jsonl([response]))
        _ = try env.writeClaudeDesktopLocalAgentFile(
            relativePath: "outputs/ignored/audit.jsonl", contents: env.jsonl([assistant(
                session: "ignored",
                output: 99)]))
        let roots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: .init(cacheRoot: env.cacheRoot), environment: [:], homeDirectory: env.root)
        #expect(roots.contains(audit.standardizedFileURL))
        #expect(!ClaudeDesktopProjectsLocator.roots(homeDirectory: env.root).contains(audit.standardizedFileURL))
        var options = CostUsageScanner.Options(claudeProjectsRoots: roots, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        for _ in 0..<2 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .claude, since: day, until: day, now: day, options: options)
            #expect(report.data.first?.inputTokens == 20)
            #expect(report.data.first?.outputTokens == 12)
        }
    }

    @Test(arguments: [nil, .regular, .spendDashboard] as [CostUsageReportContext?])
    func `Cowork audit request_id matches the transcript copy of the same response`(
        context: CostUsageReportContext?) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 16)
        let files = try Self.writeCoworkAuditAndTranscript(env: env, day: day)
        let roots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: .init(cacheRoot: env.cacheRoot), environment: [:], homeDirectory: env.root)
        var options = CostUsageScanner.Options(claudeProjectsRoots: roots, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        func load() throws -> CostUsageDailyReport {
            try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude,
                since: day,
                until: day,
                now: day,
                options: options,
                reportContext: context,
                checkCancellation: nil)
        }
        for _ in 0..<2 {
            let report = try load()
            #expect(report.data.first?.inputTokens == 100)
            #expect(report.data.first?.cacheReadTokens == 2000)
            #expect(report.data.first?.outputTokens == 150)
        }

        // Cowork appends the next response to both files.
        let next = Self.coworkLines(
            env: env,
            day: day,
            request: "req-2",
            usage: (input: 30, cacheRead: 0),
            outputs: (1, 40))
        for (url, line) in [(files.audit, next.audit), (files.transcript, next.transcript)] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl([line]).utf8))
            try handle.close()
        }
        let appended = try load()
        #expect(appended.data.first?.inputTokens == 130)
        #expect(appended.data.first?.cacheReadTokens == 2000)
        #expect(appended.data.first?.outputTokens == 190)
    }

    static func writeCoworkAuditAndTranscript(
        env: CostUsageTestEnvironment,
        day: Date) throws -> (audit: URL, transcript: URL)
    {
        let lines = Self.coworkLines(
            env: env,
            day: day,
            request: "req-1",
            usage: (input: 100, cacheRead: 2000),
            outputs: (2, 150))
        return try (
            env.writeClaudeDesktopLocalAgentFile(relativePath: "audit.jsonl", contents: env.jsonl([lines.audit])),
            env.writeClaudeDesktopLocalAgentProjectFile(
                relativePath: "project/session.jsonl",
                contents: env.jsonl([lines.transcript])))
    }

    /// The audit copy carries the early-stream output and snake_case IDs; the transcript copy has the final output.
    static func coworkLines(
        env: CostUsageTestEnvironment,
        day: Date,
        request: String,
        usage: (input: Int, cacheRead: Int),
        outputs: (audit: Int, transcript: Int)) -> (audit: [String: Any], transcript: [String: Any])
    {
        func line(ids: [String: String], output: Int) -> [String: Any] {
            var line: [String: Any] = [
                "type": "assistant", "timestamp": env.isoString(for: day),
                "message": [
                    "id": "cowork-\(request)", "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": usage.input,
                        "cache_read_input_tokens": usage.cacheRead,
                        "output_tokens": output,
                    ],
                ],
            ]
            line.merge(ids) { $1 }
            return line
        }
        return (
            line(ids: ["session_id": "cowork", "request_id": request], output: outputs.audit),
            line(ids: ["sessionId": "cowork", "requestId": request], output: outputs.transcript))
    }

    @Test
    func `claude daily report includes nested desktop local agent projects`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 5)
        let iso0 = env.isoString(for: day)
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-test-model",
                "usage": [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 30,
                    "cache_read_input_tokens": 20,
                    "output_tokens": 40,
                ],
            ],
        ]
        let nestedAssistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-test-model",
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 5,
                ],
            ],
        ]
        let currentAssistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-test-model",
                "usage": [
                    "input_tokens": 7,
                    "output_tokens": 3,
                ],
            ],
        ]
        let decoyAssistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-test-model",
                "usage": [
                    "input_tokens": 999,
                    "output_tokens": 999,
                ],
            ],
        ]
        let projectsRoot = try env.writeClaudeDesktopLocalAgentProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([assistant]))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nestedProjectsRoot = try env.writeNestedClaudeDesktopLocalAgentProjectFile(
            relativePath: "project-b/session-b.jsonl",
            contents: env.jsonl([nestedAssistant]))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let currentProjectsRoot = try env.writeClaudeDesktopCodeSessionProjectFile(
            relativePath: "project-c/session-c.jsonl",
            contents: env.jsonl([currentAssistant]))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let decoyProjectsRoot = try env.writeClaudeDesktopLocalAgentFile(
            relativePath: "outputs/node_modules/package/.claude/projects/project-decoy/session-decoy.jsonl",
            contents: env.jsonl([decoyAssistant]))
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let discovered = CostUsageScanner.defaultClaudeProjectsRoots(
            options: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            environment: [:],
            homeDirectory: env.root)
        #expect(discovered.contains(projectsRoot.standardizedFileURL))
        #expect(discovered.contains(nestedProjectsRoot.standardizedFileURL))
        #expect(discovered.contains(currentProjectsRoot.standardizedFileURL))
        #expect(!discovered.contains(decoyProjectsRoot.standardizedFileURL))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: discovered,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 137)
        #expect(report.data[0].cacheCreationTokens == 30)
        #expect(report.data[0].cacheReadTokens == 20)
        #expect(report.data[0].outputTokens == 48)
        #expect(report.data[0].totalTokens == 235)
    }

    @Test
    func `current desktop shared claude projects root remains discovered`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 5)
        let sessionID = "desktop-cli-session"
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "message": [
                "model": "claude-test-model",
                "usage": [
                    "input_tokens": 11,
                    "cache_read_input_tokens": 13,
                    "output_tokens": 4,
                ],
            ],
        ]
        // Current Desktop's cliSessionId points to the matching JSONL in this shared root.
        let sharedProjectsRoot = try env.writeClaudeDesktopSharedProjectFile(
            relativePath: "desktop-project/\(sessionID).jsonl",
            contents: env.jsonl([assistant]))
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let discovered = CostUsageScanner.defaultClaudeProjectsRoots(
            options: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            environment: [:],
            homeDirectory: env.root)
        #expect(discovered.contains(sharedProjectsRoot.standardizedFileURL))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: discovered,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 11)
        #expect(report.data[0].cacheReadTokens == 13)
        #expect(report.data[0].outputTokens == 4)
        #expect(report.data[0].totalTokens == 28)
    }

    @Test
    func `Claude config root is one relative literal and always owns a projects child`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostUsageScanner-ClaudePaths-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("probe", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let literal = " first, second "
        let roots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: CostUsageScanner.Options(cacheRoot: root.appendingPathComponent("cache")),
            environment: [ClaudeConfigPaths.configDirectoryEnvironmentKey: literal],
            homeDirectory: root.appendingPathComponent("home"),
            workingDirectory: workingDirectory)
        #expect(roots == [workingDirectory
                .appendingPathComponent(literal, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .standardizedFileURL])

        let projectsNamedRoot = CostUsageScanner.defaultClaudeProjectsRoots(
            options: CostUsageScanner.Options(cacheRoot: root.appendingPathComponent("cache")),
            environment: [ClaudeConfigPaths.configDirectoryEnvironmentKey: "projects"],
            homeDirectory: root.appendingPathComponent("home"),
            workingDirectory: workingDirectory)
        #expect(projectsNamedRoot == [workingDirectory
                .appendingPathComponent("projects/projects", isDirectory: true)
                .standardizedFileURL])

        let relativeHomeRoots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: CostUsageScanner.Options(cacheRoot: root.appendingPathComponent("cache")),
            environment: ["HOME": "relative-home", ClaudeConfigPaths.configDirectoryEnvironmentKey: ""],
            homeDirectory: root.appendingPathComponent("ignored-home"),
            workingDirectory: workingDirectory)
        #expect(relativeHomeRoots.contains(workingDirectory
                .appendingPathComponent("relative-home/.claude/projects", isDirectory: true)
                .standardizedFileURL))
    }
}
