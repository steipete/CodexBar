import Foundation
import Testing
@testable import CodexBarCore

struct AgentSessionExecutableTests {
    @Test(arguments: ["codex", "claude"])
    func `preserved CLI arguments can mention application bundle paths`(provider: String) {
        let arguments = [
            "/usr/local/bin/\(provider)", provider == "codex" ? "exec" : "-p",
            "Inspect /Applications/Example.app/Contents/Info.plist",
        ]
        let record = Self.record(arguments, pid: 101, hasArguments: true)

        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [101])
        #expect(AgentPSOutputParser.provider(for: record)?.rawValue == provider)
        #expect(AgentPSOutputParser.source(for: record) == .cli)
    }

    @Test(arguments: ["codex", "claude"])
    func `preserved CLI prompts cannot change provider or desktop source`(provider: String) {
        let record = Self.record(
            [
                "/usr/local/bin/\(provider)",
                "Compare /Applications/Example.app/Contents with " +
                    "~/Library/Application Support/Claude/claude-code/claude",
            ],
            pid: 101,
            hasArguments: true)

        #expect(record.executableBasename == provider)
        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [101])
        #expect(AgentPSOutputParser.provider(for: record)?.rawValue == provider)
        #expect(AgentPSOutputParser.source(for: record) == .cli)
    }

    @Test(arguments: [false, true])
    func `preserved wrapper arguments keep their existing source classification`(desktop: Bool) {
        let executable = desktop
            ? "/synthetic/Library/Application Support/Claude/claude-code/claude"
            : "/usr/local/bin/claude"
        let record = Self.record(["/usr/bin/disclaimer", executable], pid: 101, hasArguments: true)

        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [101])
        #expect(AgentPSOutputParser.source(for: record) == (desktop ? .desktopApp : .cli))
    }

    @Test(arguments: [false, true])
    func `bundle executable policies remain distinct from prompt text`(hasArguments: Bool) {
        let executables = [
            "/usr/local/bin/codex",
            "/usr/local/bin/claude",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Other.app/Contents/MacOS/codex",
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "./Codex Computer Use.app/Contents/MacOS/helper",
            "./claude tools.app/Contents/MacOS/helper",
        ]
        let records = executables.enumerated().map { index, path in
            Self.record([path, "Inspect README.md"], pid: Int32(index + 1), hasArguments: hasArguments)
        }

        #expect(AgentPSOutputParser.agentProcesses(from: records).map(\.pid) == [1, 2, 3, 4])
    }

    @Test
    func `preserved app server arguments may refer to an application bundle`() {
        let record = Self.record(
            [
                "/usr/local/bin/codex", "-c",
                #"shell_environment_policy.set.REVIEW_PATH="/Applications/Example.app/Contents""#, "app-server",
            ],
            pid: 101,
            hasArguments: true)

        #expect(AgentPSOutputParser.hasCodexAppServer(in: [record]))
        #expect(AgentPSOutputParser.agentProcesses(from: [record]).isEmpty)
    }

    @Test(arguments: [
        nil,
        [],
        ["/tmp/Example.app/Library/Application Support/Claude/claude-code/claude"]
    ] as [[String]?])
    func `legacy Claude paths with spaces retain their existing exception`(arguments: [String]?) {
        let record = AgentProcessRecord(
            pid: 101,
            ppid: 1,
            startedAt: nil,
            command: "/tmp/Example.app/Library/Application Support/Claude/claude-code/claude",
            arguments: arguments)

        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [101])
        #expect(AgentPSOutputParser.source(for: record) == .desktopApp)
    }

    @Test(arguments: ["codex", "claude"])
    func `scanner keeps command-only CLI rows before a transcript exists`(provider: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let command = "/usr/local/bin/\(provider) \(provider == "codex" ? "exec" : "-p") " +
            "Inspect README.md"
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in "101 1 Mon Jul 6 09:03:00 2026 \(command)" },
            cwdProvider: { _, _ in [101: "/synthetic/project"] })

        let sessions = await scanner.scan(
            environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path],
            includeFileOnlySessions: false)

        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.id == "pid:101")
        #expect(session.pid == 101)
        #expect(session.provider.rawValue == provider)
        #expect(session.source == .cli)
        #expect(session.projectName == "project")
    }

    private static func record(_ arguments: [String], pid: Int32, hasArguments: Bool) -> AgentProcessRecord {
        AgentProcessRecord(
            pid: pid,
            ppid: 1,
            startedAt: nil,
            command: arguments.joined(separator: " "),
            arguments: hasArguments ? arguments : nil)
    }
}
