import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostBreakdownTests {
    @Test
    func `pi sessions and projects partition the pi total`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.write("--alpha--/2026-04-10T10-00-00-000Z_alpha.jsonl", [
            fixture.header(id: "alpha-session", cwd: "/Users/test/projects/alpha"),
            fixture.assistant(
                id: "a1",
                provider: "openai-codex",
                model: "gpt-5.4",
                input: 100,
                output: 20,
                cacheRead: 30),
            fixture.assistant(
                id: "a2",
                provider: "amazon-bedrock",
                model: "global.anthropic.claude-sonnet-4-6",
                input: 40,
                output: 10),
        ])
        try fixture.write("--beta--/2026-04-10T11-00-00-000Z_beta.jsonl", [
            fixture.header(id: "beta-session", cwd: "/Users/test/projects/beta/"),
            fixture.assistant(id: "b1", provider: "anthropic", model: "claude-sonnet-4-6", input: 50, output: 25),
            fixture.assistant(id: "b2", provider: "example-backend", model: "fixture-model", input: 7, output: 3),
        ])
        try fixture.write("2026-04-10T12-00-00-000Z_loose.jsonl", [
            fixture.header(id: "loose-session", cwd: nil),
            fixture.assistant(id: "c1", provider: "openai-codex", model: "gpt-5.4", input: 5, output: 5),
        ])

        let result = try fixture.scan()
        let summary = try #require(result.report.summary)
        #expect(result.detailsAreComplete)
        #expect(result.sessions.count == 3)
        #expect(result.sessions.compactMap(\.totalTokens).reduce(0, +) == summary.totalTokens)
        #expect(result.projects.compactMap(\.totalTokens).reduce(0, +) == summary.totalTokens)
        let totalCost = try #require(summary.totalCostUSD)
        #expect(abs(result.sessions.compactMap(\.costUSD).reduce(0, +) - totalCost) < 1e-9)
        #expect(abs(result.projects.compactMap(\.totalCostUSD).reduce(0, +) - totalCost) < 1e-9)

        let projects = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.name, $0) })
        #expect(projects["alpha"]?.path == "/Users/test/projects/alpha")
        #expect(projects["beta"]?.path == "/Users/test/projects/beta")
        #expect(projects["beta"]?.sources.isEmpty == true)
        #expect(projects[CostUsageProjectBreakdown.unknownProjectName]?.path == nil)
        #expect(projects[CostUsageProjectBreakdown.unknownProjectName]?.totalTokens == 10)

        let alpha = try #require(result.sessions.first { $0.sessionID == "alpha-session" })
        #expect(alpha.projectPath == "/Users/test/projects/alpha")
        #expect(alpha.projectName == "alpha")
        #expect(alpha.inputTokens == 170)
        #expect(alpha.cachedInputTokens == 30)
        #expect(alpha.outputTokens == 30)
        #expect(alpha.totalTokens == 200)
        #expect(alpha.requestCount == 2)
        #expect(Set(alpha.modelBreakdowns.map(\.modelName)) == ["gpt-5.4", "global.anthropic.claude-sonnet-4-6"])
        #expect(alpha.toolActivitySource == nil)
        #expect(alpha.requestDetailSource == nil)
        let loose = try #require(result.sessions.first { $0.sessionID == "loose-session" })
        #expect(loose.projectPath == nil)
        #expect(loose.projectName == nil)
    }

    @Test
    func `pi session without header cwd uses the project folder slug as its name`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.write("--tmp-demo--/2026-04-10T10-00-00-000Z_demo.jsonl", [
            fixture.header(id: "demo-session", cwd: nil),
            fixture.assistant(id: "d1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])

        let result = try fixture.scan()
        let project = try #require(result.projects.first)
        #expect(result.projects.count == 1)
        #expect(project.name == "tmp-demo")
        #expect(project.path == nil)
        #expect(result.sessions.first?.projectName == "tmp-demo")
        #expect(result.sessions.first?.projectPath == nil)
    }

    @Test
    func `pi session title follows the latest session info name`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let url = try fixture.write("2026-04-10T10-00-00-000Z_title.jsonl", [
            fixture.header(id: "title-session", cwd: "/Users/test/projects/alpha"),
            ["type": "session_info", "name": "Refactor parser"],
            fixture.assistant(id: "t1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
            ["type": "session_info", "name": "Fix flaky\ntest"],
        ])
        #expect(try fixture.scan().sessions.first?.title == "Fix flakytest")

        try fixture.append(to: url, [["type": "session_info", "name": ""]])
        let cleared = try fixture.scan(now: fixture.day.addingTimeInterval(1))
        #expect(cleared.sessions.count == 1)
        #expect(cleared.sessions.first?.title == nil)
        #expect(cleared.sessions.first?.totalTokens == 15)
    }

    @Test
    func `omp title line names the session`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        var titledHeader = fixture.header(id: "slot-session", cwd: "/Users/test/projects/alpha")
        titledHeader["title"] = "Header title"
        try fixture.writeOMP("2026-04-10T10-00-00-000Z_slot.jsonl", [
            ["type": "title", "title": "Draft release notes"],
            titledHeader,
            fixture.assistant(id: "s1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])
        var headerOnly = fixture.header(id: "header-session", cwd: "/Users/test/projects/beta")
        headerOnly["title"] = "Review changelog"
        try fixture.writeOMP("2026-04-10T11-00-00-000Z_header.jsonl", [
            headerOnly,
            fixture.assistant(id: "h1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])

        let titles = try Dictionary(uniqueKeysWithValues: fixture.scan().sessions.map { ($0.sessionID, $0.title) })
        #expect(titles["slot-session"] == "Draft release notes")
        #expect(titles["header-session"] == "Review changelog")
    }

    @Test
    func `pi appended rows and rename update the owning session without duplicating usage`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let url = try fixture.write("2026-04-10T10-00-00-000Z_append.jsonl", [
            fixture.header(id: "append-session", cwd: "/Users/test/projects/alpha"),
            fixture.assistant(id: "p1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])
        let first = try fixture.scan()
        #expect(first.sessions.first?.totalTokens == 15)
        #expect(first.sessions.first?.title == nil)

        try fixture.append(to: url, [
            fixture.assistant(id: "p2", provider: "openai-codex", model: "gpt-5.4", input: 20, output: 10),
            ["type": "session_info", "name": "Refactor parser"],
        ])
        let counter = PiBreakdownParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let second = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try fixture.scan(now: fixture.day.addingTimeInterval(1))
        }
        #expect(counter.value == 1)
        #expect(second.report.summary?.totalTokens == 45)
        #expect(second.sessions.count == 1)
        #expect(second.sessions.first?.totalTokens == 45)
        #expect(second.sessions.first?.title == "Refactor parser")
        #expect(second.projects.map(\.path) == ["/Users/test/projects/alpha"])
        #expect(second.projects.first?.totalTokens == 45)
        let cached = try #require(PiSessionCostCacheIO.load(cacheRoot: fixture.env.cacheRoot).files.values.first)
        #expect(cached.projectPath == "/Users/test/projects/alpha")
        #expect(cached.title == "Refactor parser")
    }

    @Test
    func `pi atomic rewrite with a new cwd moves the session to the new project`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let relativePath = "2026-04-10T10-00-00-000Z_move.jsonl"
        let rows: (String) -> [[String: Any]] = { cwd in
            [
                fixture.header(id: "move-session", cwd: cwd),
                fixture.assistant(id: "m1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
            ]
        }
        try fixture.write(relativePath, rows("/Users/test/projects/alpha"))
        #expect(try fixture.scan().projects.map(\.name) == ["alpha"])

        try fixture.write(relativePath, rows("/Users/test/projects/beta"))
        let moved = try fixture.scan(now: fixture.day.addingTimeInterval(1))
        #expect(moved.projects.map(\.name) == ["beta"])
        #expect(moved.projects.first?.totalTokens == 15)
        #expect(moved.sessions.map(\.projectPath) == ["/Users/test/projects/beta"])
    }

    @Test
    func `pi same-size in-place rewrite keeps cached session rows until forced rescan`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let rows: (String) -> [[String: Any]] = { name in
            [
                fixture.header(id: "rewrite-session", cwd: "/Users/test/projects/\(name)"),
                fixture.assistant(id: "r1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
            ]
        }
        let original = try fixture.env.jsonl(rows("alpha"))
        let replacement = try fixture.env.jsonl(rows("gamma"))
        #expect(original.utf8.count == replacement.utf8.count)
        let url = try fixture.write("2026-04-10T10-00-00-000Z_rewrite.jsonl", rows("alpha"))
        let stableModifiedAt = Date(timeIntervalSince1970: floor(fixture.day.timeIntervalSince1970))
        try FileManager.default.setAttributes([.modificationDate: stableModifiedAt], ofItemAtPath: url.path)
        #expect(try fixture.scan().projects.map(\.name) == ["alpha"])

        try replacement.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stableModifiedAt], ofItemAtPath: url.path)
        #expect(try fixture.scan(now: fixture.day.addingTimeInterval(1)).projects.map(\.name) == ["alpha"])

        var forced = fixture.options
        forced.forceRescan = true
        let refreshed = try fixture.scan(now: fixture.day.addingTimeInterval(2), options: forced)
        #expect(refreshed.projects.map(\.name) == ["gamma"])
        #expect(refreshed.sessions.map(\.projectPath) == ["/Users/test/projects/gamma"])
    }

    @Test
    func `pi duplicate session across overlapping roots yields one session row`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let header = fixture.header(id: "shared-session", cwd: "/Users/test/projects/alpha")
        let shared = fixture.assistant(
            id: "shared-turn",
            provider: "openai-codex",
            model: "gpt-5.4",
            input: 10,
            output: 5)
        try fixture.write("2026-04-10T10-00-00-000Z_shared.jsonl", [
            header,
            shared,
            fixture.assistant(id: "pi-turn", provider: "openai-codex", model: "gpt-5.4", input: 7, output: 3),
        ])
        try fixture.writeOMP("nested/2026-04-10T10-00-00-000Z_shared.jsonl", [
            header,
            shared,
            fixture.assistant(id: "omp-turn", provider: "openai-codex", model: "gpt-5.4", input: 20, output: 10),
        ])

        let result = try fixture.scan()
        #expect(result.report.summary?.totalTokens == 55)
        #expect(result.sessions.count == 1)
        #expect(result.sessions.first?.totalTokens == 55)
        #expect(result.sessions.first?.requestCount == 3)
        #expect(result.projects.map(\.totalTokens) == [55])
    }

    @Test
    func `pi symlinked session root yields one session row`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.write("2026-04-10T10-00-00-000Z_linked.jsonl", [
            fixture.header(id: "linked-session", cwd: "/Users/test/projects/alpha"),
            fixture.assistant(id: "l1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])
        let alias = fixture.env.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.env.root)
        var options = fixture.options
        options.ompSessionsRoot = alias.appendingPathComponent(
            fixture.env.piSessionsRoot.lastPathComponent,
            isDirectory: true)

        let result = try fixture.scan(options: options)
        #expect(result.isComplete)
        #expect(PiSessionCostCacheIO.load(cacheRoot: fixture.env.cacheRoot).files.count == 1)
        #expect(result.report.summary?.totalTokens == 15)
        #expect(result.sessions.count == 1)
        #expect(result.sessions.first?.totalTokens == 15)
    }

    @Test
    func `pi breakdowns honor the requested day range`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let nextDay = fixture.day.addingTimeInterval(24 * 60 * 60)
        try fixture.write("2026-04-10T10-00-00-000Z_span.jsonl", [
            fixture.header(id: "span-session", cwd: "/Users/test/projects/alpha"),
            fixture.assistant(id: "s1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
            fixture.assistant(
                id: "s2", provider: "openai-codex", model: "gpt-5.4", input: 20, output: 10, at: nextDay),
        ])
        try fixture.write("2026-04-10T11-00-00-000Z_early.jsonl", [
            fixture.header(id: "early-session", cwd: "/Users/test/projects/beta"),
            fixture.assistant(id: "e1", provider: "openai-codex", model: "gpt-5.4", input: 40, output: 0),
        ])

        let both = try fixture.scan(since: fixture.day, until: nextDay, now: nextDay)
        #expect(both.sessions.count == 2)
        #expect(both.report.summary?.totalTokens == 85)

        let secondDay = try fixture.scan(since: nextDay, until: nextDay, now: nextDay)
        #expect(secondDay.report.summary?.totalTokens == 30)
        #expect(secondDay.sessions.map(\.sessionID) == ["span-session"])
        #expect(secondDay.sessions.first?.totalTokens == 30)
        #expect(secondDay.projects.map(\.name) == ["alpha"])
        #expect(secondDay.projects.first?.daily.map(\.totalTokens) == [30])
    }

    @Test
    func `pi debounced read returns the cached breakdowns without reparsing`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.write("2026-04-10T10-00-00-000Z_cached.jsonl", [
            fixture.header(id: "cached-session", cwd: "/Users/test/projects/alpha"),
            ["type": "session_info", "name": "Refactor parser"],
            fixture.assistant(id: "c1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])
        let first = try fixture.scan()

        var debounced = fixture.options
        debounced.refreshMinIntervalSeconds = 3600
        let counter = PiBreakdownParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let second = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try fixture.scan(now: fixture.day.addingTimeInterval(1), options: debounced)
        }
        #expect(counter.value == 0)
        #expect(second.sessions == first.sessions)
        #expect(second.projects == first.projects)
        #expect(second.sessions.first?.title == "Refactor parser")
    }

    @Test
    func `native mirror reads carry no pi breakdowns`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.write("2026-04-10T10-00-00-000Z_mirror.jsonl", [
            fixture.header(id: "mirror-session", cwd: "/Users/test/projects/alpha"),
            fixture.assistant(id: "n1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
            fixture.assistant(id: "n2", provider: "anthropic", model: "claude-sonnet-4-6", input: 10, output: 5),
        ])
        #expect(try fixture.scan().sessions.count == 1)

        for provider in [UsageProvider.codex, .claude] {
            let mirror = try fixture.scan(provider: provider)
            #expect(mirror.report.summary?.totalTokens == 15)
            #expect(mirror.projects.isEmpty)
            #expect(mirror.sessions.isEmpty)
            #expect(!mirror.detailsAreComplete)
        }
    }
}

struct PiSessionCostBreakdownFixture {
    let env: CostUsageTestEnvironment
    let day: Date
    let ompSessionsRoot: URL
    let options: PiSessionCostScanner.Options

    init() throws {
        let env = try CostUsageTestEnvironment()
        let ompSessionsRoot = env.root.appendingPathComponent("omp-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: ompSessionsRoot, withIntermediateDirectories: true)
        self.env = env
        self.day = try env.makeLocalNoon(year: 2026, month: 4, day: 10)
        self.ompSessionsRoot = ompSessionsRoot
        self.options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: ompSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
    }

    func header(id: String, cwd: String?) -> [String: Any] {
        var header: [String: Any] = [
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": self.env.isoString(for: self.day),
        ]
        header["cwd"] = cwd
        return header
    }

    func assistant(
        id: String,
        provider: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        at date: Date? = nil) -> [String: Any]
    {
        [
            "type": "message",
            "id": id,
            "timestamp": self.env.isoString(for: date ?? self.day),
            "message": [
                "role": "assistant",
                "provider": provider,
                "model": model,
                "usage": [
                    "input": input,
                    "output": output,
                    "cacheRead": cacheRead,
                    "totalTokens": input + output + cacheRead,
                ],
            ],
        ]
    }

    @discardableResult
    func write(_ relativePath: String, _ rows: [[String: Any]]) throws -> URL {
        try self.env.writePiSessionFile(relativePath: relativePath, contents: self.env.jsonl(rows))
    }

    @discardableResult
    func writeOMP(_ relativePath: String, _ rows: [[String: Any]]) throws -> URL {
        let url = self.ompSessionsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.env.jsonl(rows).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(to url: URL, _ rows: [[String: Any]]) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.env.jsonl(rows).utf8))
        try handle.close()
    }

    func scan(
        provider: UsageProvider = .pi,
        since: Date? = nil,
        until: Date? = nil,
        now: Date? = nil,
        options: PiSessionCostScanner.Options? = nil) throws -> PiSessionCostScanner.DailyReportResult
    {
        try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: provider,
            since: since ?? self.day,
            until: until ?? self.day,
            now: now ?? self.day,
            options: options ?? self.options,
            checkCancellation: nil)
    }
}

private typealias Fixture = PiSessionCostBreakdownFixture

final class PiBreakdownParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
