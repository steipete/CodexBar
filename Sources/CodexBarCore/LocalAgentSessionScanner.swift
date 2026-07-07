import Foundation

public struct LocalAgentSessionScanner: Sendable {
    private struct Rollout: Sendable {
        let url: URL
        let modifiedAt: Date
        let metadata: CodexRolloutMetadata
    }

    private struct ScanContext: Sendable {
        let homeDirectory: URL
        let host: String
        let now: Date
    }

    public let config: SessionScanConfig

    public init(config: SessionScanConfig = SessionScanConfig()) {
        self.config = config
    }

    public func scan(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> [AgentSession]
    {
        let processOutput = await self.processOutput(environment: environment)
        let allProcesses = AgentPSOutputParser.parse(processOutput)
        let processes = AgentSessionCorrelation.newestProcessesFirst(
            AgentPSOutputParser.agentProcesses(from: allProcesses))
        let codexAppServerPresent = AgentPSOutputParser.hasCodexAppServer(in: allProcesses)
        let cwdByPID = await self.cwdByPID(processes.map(\ .pid), environment: environment)
        let homeDirectory = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let host = ProcessInfo.processInfo.hostName
        let rollouts = self.codexRollouts(
            now: now,
            environment: environment,
            homeDirectory: homeDirectory)
        return self.sessions(
            processes: processes,
            cwdByPID: cwdByPID,
            rollouts: rollouts,
            codexAppServerPresent: codexAppServerPresent,
            context: ScanContext(homeDirectory: homeDirectory, host: host, now: now))
    }

    private func sessions(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        rollouts: [Rollout],
        codexAppServerPresent: Bool,
        context: ScanContext) -> [AgentSession]
    {
        var sessions: [AgentSession] = []
        var matchedRolloutPaths = Set<String>()
        let claudeProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .claude }
        let claudeCWDs = Set(claudeProcesses.compactMap { cwdByPID[$0.pid] })
        let claudeTranscriptsByCWD = Dictionary(uniqueKeysWithValues: claudeCWDs.map { cwd in
            (cwd, ClaudeSessionProjectMapper.transcripts(cwd: cwd, homeDirectory: context.homeDirectory))
        })
        let claudeTranscripts = AgentSessionCorrelation.assignClaudeTranscripts(
            processes: claudeProcesses,
            cwdByPID: cwdByPID,
            transcriptsByCWD: claudeTranscriptsByCWD)

        for process in processes {
            guard let provider = AgentPSOutputParser.provider(for: process) else { continue }
            let cwd = cwdByPID[process.pid]
            switch provider {
            case .claude:
                let transcript = claudeTranscripts[process.pid]
                sessions.append(AgentSession(
                    id: transcript?.url.deletingPathExtension().lastPathComponent ?? "pid:\(process.pid)",
                    provider: .claude,
                    source: AgentPSOutputParser.source(for: process),
                    state: self.config.state(
                        lastActivityAt: transcript?.modifiedAt,
                        now: context.now,
                        hasLiveProcess: true),
                    pid: process.pid,
                    cwd: cwd,
                    projectName: Self.projectName(cwd),
                    startedAt: process.startedAt,
                    lastActivityAt: transcript?.modifiedAt,
                    transcriptPath: transcript?.url.path,
                    host: context.host))
            case .codex:
                let rollout = rollouts.first { candidate in
                    !matchedRolloutPaths.contains(candidate.url.path) &&
                        AgentSessionCorrelation.codexWorkingDirectoriesMatch(candidate.metadata.cwd, cwd)
                }
                if let rollout {
                    matchedRolloutPaths.insert(rollout.url.path)
                }
                let rolloutSource = rollout?.metadata.sessionSource
                sessions.append(AgentSession(
                    id: rollout?.metadata.sessionID ?? "pid:\(process.pid)",
                    provider: .codex,
                    source: rolloutSource == nil || rolloutSource == .unknown ? .cli : rolloutSource ?? .cli,
                    state: self.config.state(
                        lastActivityAt: rollout?.modifiedAt,
                        now: context.now,
                        hasLiveProcess: true),
                    pid: process.pid,
                    cwd: cwd ?? rollout?.metadata.cwd,
                    projectName: Self.projectName(cwd ?? rollout?.metadata.cwd),
                    startedAt: process.startedAt,
                    lastActivityAt: rollout?.modifiedAt,
                    transcriptPath: rollout?.url.path,
                    host: context.host))
            }
        }

        for rollout in rollouts where !matchedRolloutPaths.contains(rollout.url.path) {
            guard var session = CodexRolloutFirstLineParser.makeSession(
                metadata: rollout.metadata,
                transcriptURL: rollout.url,
                modifiedAt: rollout.modifiedAt,
                host: context.host,
                config: self.config,
                now: context.now)
            else { continue }
            session.source = AgentSessionCorrelation.fileOnlyCodexSource(
                metadataSource: session.source,
                appServerPresent: codexAppServerPresent)
            sessions.append(session)
        }

        var seen = Set<String>()
        return sessions
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .active
                }
                return (lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast) >
                    (rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast)
            }
            .filter { seen.insert("\($0.host):\($0.id)").inserted }
    }

    private func processOutput(environment: [String: String]) async -> String {
        let binary = ["/bin/ps", "/usr/bin/ps"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary,
              let result = try? await SubprocessRunner.run(
                  binary: binary,
                  arguments: ["-axo", "pid=,ppid=,lstart=,command="],
                  environment: environment,
                  timeout: 5,
                  label: "agent session process scan")
        else { return "" }
        return result.stdout
    }

    private func cwdByPID(_ pids: [Int32], environment: [String: String]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        if let lsof = self.findExecutable("lsof", environment: environment) {
            let joinedPIDs = pids.map(String.init).joined(separator: ",")
            if let result = try? await SubprocessRunner.run(
                binary: lsof,
                arguments: ["-a", "-d", "cwd", "-Fn", "-p", joinedPIDs],
                environment: environment,
                timeout: 5,
                acceptsNonZeroExit: true,
                label: "agent session cwd scan")
            {
                return LSOFCWDOutputParser.parse(result.stdout)
            }
        }

        #if os(Linux)
        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            let path = "/proc/\(pid)/cwd"
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            return (pid, destination)
        })
        #else
        return [:]
        #endif
    }

    private func codexRollouts(
        now: Date,
        environment: [String: String],
        homeDirectory: URL) -> [Rollout]
    {
        let root = URL(
            fileURLWithPath: environment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path,
            isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap(\.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let fileManager = FileManager.default

        return days.flatMap { day -> [Rollout] in
            let directory = root.appendingPathComponent(formatter.string(from: day), isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { return [] }
            return files.compactMap { file in
                guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl",
                      let modifiedAt = try? file.resourceValues(
                          forKeys: [.contentModificationDateKey]).contentModificationDate,
                      let metadata = CodexRolloutFirstLineParser.read(from: file)
                else { return nil }
                return Rollout(url: file, modifiedAt: modifiedAt, metadata: metadata)
            }
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        return path.split(separator: ":")
            .map { String($0) + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func standardized(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
