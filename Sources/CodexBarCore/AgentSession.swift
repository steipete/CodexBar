import Foundation

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case codex
        case claude
    }

    public enum Source: String, Codable, Sendable {
        case cli
        case desktopApp
        case ide
        case unknown
    }

    public enum State: String, Codable, Sendable {
        case active
        case idle
    }

    public var id: String
    public var provider: Provider
    public var source: Source
    public var state: State
    public var pid: Int32?
    public var cwd: String?
    public var projectName: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var transcriptPath: String?
    public var host: String

    public init(
        id: String,
        provider: Provider,
        source: Source,
        state: State,
        pid: Int32?,
        cwd: String?,
        projectName: String?,
        startedAt: Date?,
        lastActivityAt: Date?,
        transcriptPath: String?,
        host: String)
    {
        self.id = id
        self.provider = provider
        self.source = source
        self.state = state
        self.pid = pid
        self.cwd = cwd
        self.projectName = projectName
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.transcriptPath = transcriptPath
        self.host = host
    }
}

public struct SessionScanConfig: Equatable, Sendable {
    public var activeWindow: TimeInterval
    public var fileOnlyWindow: TimeInterval

    public init(activeWindow: TimeInterval = 120, fileOnlyWindow: TimeInterval = 30 * 60) {
        self.activeWindow = activeWindow
        self.fileOnlyWindow = fileOnlyWindow
    }

    public func state(lastActivityAt: Date?, now: Date, hasLiveProcess: Bool) -> AgentSession.State {
        guard let lastActivityAt else { return hasLiveProcess ? .active : .idle }
        return now.timeIntervalSince(lastActivityAt) <= self.activeWindow ? .active : .idle
    }
}

public struct AgentProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let startedAt: Date?
    public let command: String

    public init(pid: Int32, ppid: Int32, startedAt: Date?, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.startedAt = startedAt
        self.command = command
    }

    public var executableBasename: String {
        let firstToken = self.command.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        let firstBasename = URL(fileURLWithPath: firstToken).lastPathComponent
        if firstBasename == "disclaimer" {
            return firstBasename
        }
        if self.command.contains("Application Support/Claude/claude-code/claude") {
            return "claude"
        }
        return firstBasename
    }
}

public enum AgentPSOutputParser {
    public static func parse(_ output: String) -> [AgentProcessRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return output.split(whereSeparator: \ .isNewline).compactMap { rawLine -> AgentProcessRecord? in
            let fields = rawLine.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: \ .isWhitespace)
            guard fields.count == 8,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1])
            else { return nil }

            let dateText = fields[2...6].joined(separator: " ")
            return AgentProcessRecord(
                pid: pid,
                ppid: ppid,
                startedAt: formatter.date(from: dateText),
                command: String(fields[7]))
        }
    }

    public static func agentProcesses(from records: [AgentProcessRecord]) -> [AgentProcessRecord] {
        let candidates = records.filter { record in
            let basename = record.executableBasename.lowercased()
            if basename == "codex" {
                let arguments = self.arguments(record.command)
                return self.isCodexAgentExecutable(record.command) &&
                    !arguments.contains("app-server") &&
                    !arguments.contains("--help") &&
                    !arguments.contains("--version")
            }
            if basename == "claude" {
                return self.isClaudeAgentExecutable(record.command) && !self.isObviousClaudeHelper(record.command)
            }
            return basename == "disclaimer" && record.command.contains("claude")
        }

        let recordsByPID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0) })
        return candidates.filter { record in
            guard record.executableBasename.lowercased() == "disclaimer" else { return true }
            return !candidates.contains { child in
                child.ppid == record.pid &&
                    child.executableBasename.lowercased() == "claude" &&
                    self.normalizedClaudeArguments(child.command) == self.normalizedClaudeArguments(record.command)
            } && recordsByPID[record.ppid] == nil
        }
    }

    public static func provider(for record: AgentProcessRecord) -> AgentSession.Provider? {
        let basename = record.executableBasename.lowercased()
        if basename == "codex" {
            return .codex
        }
        if basename == "claude" || basename == "disclaimer" {
            return .claude
        }
        return nil
    }

    public static func source(for record: AgentProcessRecord) -> AgentSession.Source {
        guard self.provider(for: record) == .claude else { return .cli }
        return record.command.contains("Application Support/Claude/claude-code") ? .desktopApp : .cli
    }

    public static func hasCodexAppServer(in records: [AgentProcessRecord]) -> Bool {
        records.contains { record in
            record.executableBasename.lowercased() == "codex" &&
                self.isCodexAgentExecutable(record.command) &&
                self.arguments(record.command).contains("app-server")
        }
    }

    private static func arguments(_ command: String) -> [String] {
        command.split(whereSeparator: \ .isWhitespace).dropFirst().map(String.init)
    }

    private static func normalizedClaudeArguments(_ command: String) -> [String] {
        let arguments = self.arguments(command)
        if let index = arguments.firstIndex(where: { URL(fileURLWithPath: $0).lastPathComponent == "claude" }) {
            return Array(arguments.suffix(from: arguments.index(after: index)))
        }
        return arguments
    }

    private static func isObviousClaudeHelper(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        return lowercased.contains("--version") ||
            lowercased.contains("--help") ||
            lowercased.contains("claude-code-acp")
    }

    private static func isCodexAgentExecutable(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        guard lowercased.contains(".app/") else { return true }
        return lowercased.hasPrefix("/applications/codex.app/contents/resources/codex ") ||
            lowercased.hasPrefix("/applications/codex.app/contents/resources/codex\t")
    }

    private static func isClaudeAgentExecutable(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        return !lowercased.contains(".app/") || lowercased.contains("application support/claude/claude-code/claude")
    }
}

public enum LSOFCWDOutputParser {
    public static func parse(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in output.split(whereSeparator: \ .isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            switch prefix {
            case "p":
                currentPID = Int32(line.dropFirst())
            case "n":
                if let currentPID {
                    result[currentPID] = String(line.dropFirst())
                }
            default:
                continue
            }
        }
        return result
    }
}

public enum ClaudeSessionProjectMapper {
    public struct Transcript: Equatable, Sendable {
        public let url: URL
        public let modifiedAt: Date

        public init(url: URL, modifiedAt: Date) {
            self.url = url
            self.modifiedAt = modifiedAt
        }
    }

    public static func escapedCWD(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(value) ||
                (65...90).contains(value) ||
                (97...122).contains(value)
            return isASCIIAlphanumeric ? Character(scalar) : "-"
        })
    }

    public static func projectDirectories(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> [URL]
    {
        let standardRoot = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        return ([standardRoot] + ClaudeDesktopProjectsLocator.roots(
            homeDirectory: homeDirectory,
            fileManager: fileManager))
            .map { $0.appendingPathComponent(self.escapedCWD(cwd), isDirectory: true) }
    }

    public static func newestTranscript(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> (url: URL, modifiedAt: Date)?
    {
        self.transcripts(cwd: cwd, homeDirectory: homeDirectory, fileManager: fileManager).first
            .map { (url: $0.url, modifiedAt: $0.modifiedAt) }
    }

    public static func transcripts(
        cwd: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> [Transcript]
    {
        self.projectDirectories(cwd: cwd, homeDirectory: homeDirectory, fileManager: fileManager)
            .flatMap { directory -> [(URL, Date)] in
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles])
                else { return [] }
                return files.compactMap { file in
                    guard file.pathExtension == "jsonl",
                          let modifiedAt = try? file.resourceValues(
                              forKeys: [.contentModificationDateKey]).contentModificationDate
                    else { return nil }
                    return (file, modifiedAt)
                }
            }
            .sorted { $0.1 > $1.1 }
            .map { Transcript(url: $0.0, modifiedAt: $0.1) }
    }
}

public enum AgentSessionCorrelation {
    public static func newestProcessesFirst(_ processes: [AgentProcessRecord]) -> [AgentProcessRecord] {
        processes.sorted { lhs, rhs in
            let lhsDate = lhs.startedAt ?? .distantPast
            let rhsDate = rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.pid > rhs.pid
        }
    }

    public static func assignClaudeTranscripts(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        transcriptsByCWD: [String: [ClaudeSessionProjectMapper.Transcript]])
        -> [Int32: ClaudeSessionProjectMapper.Transcript]
    {
        var assigned: [Int32: ClaudeSessionProjectMapper.Transcript] = [:]
        var usedPaths = Set<String>()
        let unambiguousPIDs = self.unambiguousProcessIDs(processes: processes, cwdByPID: cwdByPID)
        for process in self.newestProcessesFirst(processes) {
            guard unambiguousPIDs.contains(process.pid),
                  let cwd = cwdByPID[process.pid],
                  let candidates = transcriptsByCWD[cwd]
            else { continue }
            let candidate = candidates.first { transcript in
                guard !usedPaths.contains(transcript.url.path) else { return false }
                guard let startedAt = process.startedAt else { return true }
                return transcript.modifiedAt >= startedAt
            }
            if let candidate {
                assigned[process.pid] = candidate
                usedPaths.insert(candidate.url.path)
            }
        }
        return assigned
    }

    public static func unambiguousProcessIDs(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String]) -> Set<Int32>
    {
        let grouped = Dictionary(grouping: processes.compactMap { process -> (Int32, String)? in
            guard let cwd = cwdByPID[process.pid] else { return nil }
            return (process.pid, URL(fileURLWithPath: cwd).standardizedFileURL.path)
        }, by: { $0.1 })
        return Set(grouped.values.compactMap { records in
            records.count == 1 ? records[0].0 : nil
        })
    }

    public static func codexWorkingDirectoriesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path ==
            URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    public static func fileOnlyCodexSource(
        metadataSource: AgentSession.Source,
        appServerPresent: Bool) -> AgentSession.Source
    {
        metadataSource == .unknown && appServerPresent ? .desktopApp : metadataSource
    }
}

public struct CodexRolloutMetadata: Equatable, Sendable {
    public let sessionID: String
    public let cwd: String?
    public let originator: String?
    public let source: String?

    public init(sessionID: String, cwd: String?, originator: String?, source: String?) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.originator = originator
        self.source = source
    }

    public var sessionSource: AgentSession.Source {
        let value = [self.originator, self.source]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if value.contains("desktop") || value.contains("app-server") {
            return .desktopApp
        }
        if value.contains("ide") || value.contains("vscode") || value.contains("cursor") || value.contains("zed") {
            return .ide
        }
        if value.contains("codex_exec") || value.contains("exec") || value.contains("cli") {
            return .cli
        }
        return .unknown
    }
}

public enum CodexRolloutFirstLineParser {
    public static func parse(_ line: String) -> CodexRolloutMetadata? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String)
        else { return nil }
        return CodexRolloutMetadata(
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            originator: payload["originator"] as? String,
            source: payload["source"] as? String)
    }

    public static func read(from url: URL) -> CodexRolloutMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 256 * 1024 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk.prefix(upTo: newline))
                break
            }
            data.append(chunk)
        }
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        return self.parse(line)
    }

    public static func makeSession(
        metadata: CodexRolloutMetadata,
        transcriptURL: URL,
        modifiedAt: Date,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        host: String,
        config: SessionScanConfig = SessionScanConfig(),
        now: Date = Date()) -> AgentSession?
    {
        guard pid != nil || now.timeIntervalSince(modifiedAt) <= config.fileOnlyWindow else { return nil }
        let cwd = metadata.cwd
        return AgentSession(
            id: metadata.sessionID,
            provider: .codex,
            source: metadata.sessionSource,
            state: config.state(lastActivityAt: modifiedAt, now: now, hasLiveProcess: pid != nil),
            pid: pid,
            cwd: cwd,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            startedAt: startedAt,
            lastActivityAt: modifiedAt,
            transcriptPath: transcriptURL.path,
            host: host)
    }
}
