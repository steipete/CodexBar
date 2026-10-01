import Foundation
import Testing
@testable import CodexBarCore

struct AgentProcessBasenameTests {
    @Test(arguments: [
        "", "~", "~/", "~/pi", "~/~", "~/pi/~", "~root", "~root/", "~root/..", "/", "//", "///",
        ".", "..", "./", "../", "~no-such-synthetic-user/..",
        "pi", "./pi", "../bin/pi", "pi/", "pi///", "/usr/local/bin/pi/", "foo/.", "foo/..",
        "a//..", "a//../..", "..//..", "/foo/.", "/foo/..", "~/.", "~/..", "~/pi/..",
        "/Applications/Claude.app/Contents/MacOS/Claude", "Application Support/Claude/claude-code/claude",
        "/path with spaces/omp", "./path with spaces/bun/", "a%2Fb", "a\\b", "a/\u{301}", " pi ",
    ])
    func `string basenames preserve file URL semantics`(path: String) {
        #expect(AgentProcessPath.basename(path) == URL(fileURLWithPath: path).lastPathComponent)
    }

    @Test
    func `ordinary basenames never consult directory context`() {
        var directoryReads = 0
        func directory() -> String {
            directoryReads += 1
            return "/synthetic/omp"
        }
        for index in 0..<2500 {
            #expect(AgentProcessPath.basename(
                "/synthetic/process-\(index)/node/",
                currentDirectory: directory(),
                expandTilde: { _ in directory() }) == "node")
        }
        #expect(directoryReads == 0)
        #expect(AgentProcessPath.basename("", currentDirectory: directory()) == "omp")
        #expect(directoryReads == 1)
        #expect(AgentProcessPath.basename("..", currentDirectory: directory()) == "synthetic")
        #expect(directoryReads == 2)
        #expect(AgentProcessPath.basename("~/", expandTilde: { _ in directory() }) == "omp")
        #expect(directoryReads == 3)
    }

    @Test
    func `both Foundation tilde dialects preserve relative and absolute dot semantics`() {
        let cases = [
            ("~", "~", "home"), ("~/", "home", "home"), ("~root", "~root", "root"),
            ("~root/", "~root", "root"), ("~root/..", "omp", ".."), ("~/pi/..", "..", ".."),
            ("~unknown/..", "omp", "omp"), ("foo/../~", "~", "~"),
        ]
        for (path, modern, legacy) in cases {
            for expandsBareTilde in [false, true] {
                let basename = AgentProcessPath.basename(
                    path,
                    currentDirectory: "/work/omp",
                    expandTilde: { path in
                        if path == "~root" || path.hasPrefix("~root/") {
                            return "/synthetic/root" + path.dropFirst(5)
                        }
                        if path == "~" || path.hasPrefix("~/") {
                            return "/synthetic/home" + path.dropFirst()
                        }
                        return path
                    },
                    expandsBareTilde: expandsBareTilde)
                #expect(basename == (expandsBareTilde ? legacy : modern))
            }
        }
    }

    @Test
    func `non bun dialect checks do not materialize arguments`() {
        var argumentReads = 0
        func arguments() -> [String] {
            argumentReads += 1
            return ["/opt/omp"]
        }
        for _ in 0..<2500 {
            #expect(AgentPSOutputParser.piDialect(executableBasename: "node", arguments: arguments()) == nil)
        }
        #expect(argumentReads == 0)
        #expect(AgentPSOutputParser.piDialect(executableBasename: "bun", arguments: arguments()) == .omp)
        #expect(argumentReads == 1)
    }

    @Test
    func `parser has no filesystem probing URL constructors`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCore/AgentSession.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "enum AgentProcessPath {"))
        let end = try #require(source.range(of: "public enum LSOFCWDOutputParser {"))
        let parser = String(source[start.lowerBound..<end.lowerBound])
        let hintedProbe = "URL(fileURLWithPath: \"~\", isDirectory: false)"
        #expect(parser.components(separatedBy: hintedProbe).count - 1 == 1)
        #expect(parser.replacingOccurrences(of: hintedProbe, with: "").contains("URL(fileURLWithPath:") == false)
        #expect(!parser.contains("fileExists"))
        #expect(!parser.contains("attributesOfItem"))
        #expect(!parser.contains("lstat("))
        let enumerator = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCore/DarwinProcessEnumerator.swift"),
            encoding: .utf8)
        #expect(enumerator.components(separatedBy: "AgentProcessRecord(").count - 1 == 0)
    }

    @Test
    func `agent classification preserves argv and portable command behavior`() {
        let commands = [
            ["node", "/opt/pi/index.js"], ["bun", "/opt/omp"], ["bun", "/opt/omp/"],
            ["bun", "/opt/omp bundle/tool"], ["bun", "/opt/agent tools/omp"], ["bun", "--help", "omp"],
            ["bun", "./omp"], ["bun", ""], ["bun", "."], ["bun", ".."], ["bun", "~"],
            ["pi"], ["pi/"], ["PI"], ["./pi", "--session-dir", "/project with spaces"],
            ["omp", "--profile", "work"], ["../bin/omp/"], ["omp", "--version"],
            ["codex", "exec"], ["./codex/", "exec"], ["codex", "app-server"], ["codex", "--help"],
            ["claude"], ["claude", "--version"], ["claude-code-acp"],
            ["/Applications/Claude.app/Contents/MacOS/Claude"],
            ["/Users/test/Library/Application Support/Claude/claude-code/claude", "--resume"],
            ["disclaimer", "/Users/test/Library/Application Support/Claude/claude-code/claude", "--resume"],
            ["pi", "Application", "Support/Claude/claude-code/claude"],
            ["bun", "Application", "Support/Claude/claude-code/claude", "omp"],
            ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server"],
            ["/"], [""], ["~"], ["~/"], ["."], [".."], ["/foo/."], ["/foo/.."], [],
        ]
        for arguments in commands {
            for preservesArguments in [false, true] {
                let record = AgentProcessRecord(
                    pid: 1,
                    ppid: 0,
                    startedAt: nil,
                    command: arguments.joined(separator: " "),
                    arguments: preservesArguments ? arguments : nil)
                let expected = Self.legacyClassification(record)
                #expect(record.executableBasename == expected.basename)
                #expect(AgentPSOutputParser.piDialect(for: record) == expected.dialect)
                #expect(AgentPSOutputParser.provider(for: record) == expected.provider)
                if preservesArguments {
                    #expect(AgentPSOutputParser.piDialect(arguments: arguments) == expected.dialect)
                }
            }
        }
    }

    @Test
    func `agent selection retains ordering helpers wrappers and app servers`() {
        let commands = [
            "node /opt/pi/index.js", "bun /opt/omp", "pi/", "./omp/", "codex exec", "claude",
            "omp --version", "bun omp --help", "codex app-server", "claude --help",
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "disclaimer /Users/test/Library/Application Support/Claude/claude-code/claude --resume",
            "/Users/test/Library/Application Support/Claude/claude-code/claude --resume",
        ]
        let records = commands.enumerated().map { index, command in
            AgentProcessRecord(pid: Int32(index + 1), ppid: index == 12 ? 12 : 0, startedAt: nil, command: command)
        }
        #expect(AgentPSOutputParser.agentProcesses(from: records).map(\.pid) == [2, 3, 4, 5, 6, 13])
    }

    /// Frozen pre-optimization classifier, kept as the equivalence oracle for awkward argv boundaries.
    private static func legacyClassification(_ record: AgentProcessRecord) -> (
        basename: String, dialect: AgentSession.Dialect?, provider: AgentSession.Provider?)
    {
        let arguments = record.arguments ?? record.command.split(whereSeparator: \.isWhitespace).map(String.init)
        var basename = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        if basename != "disclaimer", record.command.contains("Application Support/Claude/claude-code/claude") {
            basename = AgentSession.Provider.claude.rawValue
        }
        let first = URL(fileURLWithPath: basename).lastPathComponent.lowercased()
        let dialect: AgentSession.Dialect? = switch first {
        case "pi": .pi
        case "omp": .omp
        case "bun": arguments.dropFirst().contains {
                URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "omp"
            } ? .omp : nil
        default: nil
        }
        let provider: AgentSession.Provider? = if let direct = AgentSession.Provider(rawValue: basename.lowercased()),
                                                  direct != .pi
        {
            direct
        } else if basename.lowercased() == "disclaimer" {
            .claude
        } else if dialect != nil,
                  !["--help", "--version", "--smoke-test", "__omp_worker_"].contains(where: {
                      record.command.lowercased().contains($0)
                  })
        {
            .pi
        } else {
            nil
        }
        return (basename, dialect, provider)
    }
}
