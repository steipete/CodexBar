import Foundation
#if os(macOS)
import Security
#endif

final class FutureModificationDateClamp: @unchecked Sendable {
    private let lock = NSLock()
    private var clampDate: Date?

    init(clampDate: Date? = nil) {
        self.clampDate = clampDate
    }

    func clamp(url _: URL, modifiedAt: Date, now: Date) -> Date {
        guard modifiedAt > now else { return modifiedAt }
        return self.lock.withLock {
            if let clampDate = self.clampDate {
                return min(clampDate, now)
            }
            self.clampDate = now
            return now
        }
    }
}

enum ChatGPTCodexProcessTrust {
    #if os(macOS)
    static func isTrusted(
        _ pid: Int32,
        executablePath: (Int32) -> String? = DarwinProcessEnumerator.executablePath,
        resolvePath: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
        processIsTrusted: (Int32) -> Bool = Self.isOpenAIProcess,
        appIsTrusted: (String) -> Bool = { ChatGPTBundleTrustCache.shared.isTrusted($0) }) -> Bool
    {
        guard let path = executablePath(pid),
              AgentPSOutputParser.chatGPTCodexExecutablePaths.contains(path),
              resolvePath(path) == path
        else { return false }
        // Check the running code, not argv or a cached on-disk pathname. Validate the outer app's seal and identity.
        return processIsTrusted(pid) && appIsTrusted("/Applications/ChatGPT.app")
    }

    private static func isOpenAIProcess(_ pid: Int32) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: pid] as CFDictionary, SecCSFlags(), &code) == errSecSuccess,
            let code
        else { return false }
        var requirement: SecRequirement?
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecRequirementCreateWithString(
            requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
    #else
    static func isTrusted(_: Int32) -> Bool {
        false
    }
    #endif
}

#if os(macOS)
final class ChatGPTBundleTrustCache: @unchecked Sendable {
    typealias Identity = [URL: NSDictionary]
    static let shared = ChatGPTBundleTrustCache()
    private let lock = NSLock()
    private var trustedIdentity: Identity?

    func isTrusted(
        _ path: String,
        identity: (String) -> Identity? = ChatGPTBundleTrustCache.identity,
        assess: (String) -> Bool = { CodexLaunchPreflight.isLaunchCandidateAllowed(path: $0) }) -> Bool
    {
        self.lock.withLock {
            guard let current = identity(path) else {
                self.trustedIdentity = nil
                return false
            }
            if self.trustedIdentity == current { return true }
            self.trustedIdentity = nil
            guard assess(path), identity(path) == current else { return false }
            self.trustedIdentity = current
            return true
        }
    }

    static func identity(_ path: String) -> Identity? {
        let bundle = URL(fileURLWithPath: path)
        // Read Info.plist directly: Bundle caches it across in-process app updates.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".."
        else { return nil }
        var identity: Identity = [:]
        for url in [
            bundle,
            plist,
            bundle.appendingPathComponent("Contents/MacOS/\(executable)"),
            bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
        ] {
            guard url.resolvingSymlinksInPath().path == url.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.systemNumber] != nil, attributes[.systemFileNumber] != nil,
                  attributes[.modificationDate] != nil
            else { return nil }
            identity[url] = attributes as NSDictionary
        }
        return identity
    }
}
#endif

public struct LocalAgentSessionScanner: Sendable {
    typealias ProcessOutputProvider = @Sendable ([String: String]) async -> String
    typealias CWDProvider = @Sendable ([Int32], [String: String]) async -> [Int32: String]
    typealias ProcessEnvironmentProvider = @Sendable ([Int32]) async -> [Int32: [String: String]]
    typealias AppServerTrustValidator = @Sendable (AgentProcessRecord) -> Bool

    public struct ScanResult: Sendable {
        public let sessions: [AgentSession]
        public let latestRolloutActivityAt: Date?

        public init(sessions: [AgentSession] = [], latestRolloutActivityAt: Date? = nil) {
            self.sessions = sessions
            self.latestRolloutActivityAt = latestRolloutActivityAt
        }
    }

    private typealias RolloutCandidate = (url: URL, modifiedAt: Date)
    private struct Rollout: Sendable {
        let url: URL
        let modifiedAt: Date
        let metadata: CodexRolloutMetadata
    }

    private struct ScanContext: Sendable {
        let homeDirectory: URL
        let host: String
        let now: Date
        let codexAppServerPresent: Bool
        let includeUnmatchedCodexRollouts: Bool
        let threadMetadata: [String: CodexThreadMetadata]
        let piFamilySessions: [AgentSession]
    }

    public let config: SessionScanConfig
    private let futureModificationDateClamp = FutureModificationDateClamp()
    private let processOutputProvider: ProcessOutputProvider?
    private let cwdProvider: CWDProvider?
    private let processEnvironmentProvider: ProcessEnvironmentProvider?
    private let appServerTrustValidator: AppServerTrustValidator
    private let rolloutMetadataReader: @Sendable (URL) -> CodexRolloutMetadata?
    private let directoryScanStartedAt: @Sendable () -> Date
    private let didVisitDirectoryEntry: (@Sendable () -> Void)?

    public init(config: SessionScanConfig = SessionScanConfig()) {
        self.init(config: config, processOutputProvider: nil, cwdProvider: nil)
    }

    init(
        config: SessionScanConfig = SessionScanConfig(),
        processOutputProvider: ProcessOutputProvider?,
        cwdProvider: CWDProvider?,
        processEnvironmentProvider: ProcessEnvironmentProvider? = nil,
        appServerTrustValidator: @escaping AppServerTrustValidator = {
            ChatGPTCodexProcessTrust.isTrusted($0.pid)
        },
        rolloutMetadataReader: @escaping @Sendable (URL) -> CodexRolloutMetadata? = {
            CodexRolloutFirstLineParser.read(from: $0)
        },
        directoryScanStartedAt: @escaping @Sendable () -> Date = Date.init,
        didVisitDirectoryEntry: (@Sendable () -> Void)? = nil)
    {
        self.config = config
        self.processOutputProvider = processOutputProvider
        self.cwdProvider = cwdProvider
        self.processEnvironmentProvider = processEnvironmentProvider
        self.appServerTrustValidator = appServerTrustValidator
        self.rolloutMetadataReader = rolloutMetadataReader
        self.directoryScanStartedAt = directoryScanStartedAt
        self.didVisitDirectoryEntry = didVisitDirectoryEntry
    }

    @concurrent
    public func scan(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFileOnlySessions: Bool = true) async -> [AgentSession]
    {
        await self.scanWithActivity(
            now: now,
            environment: environment,
            includeFileOnlySessions: includeFileOnlySessions,
            includeRolloutActivity: false).sessions
    }

    /// Activity is a timestamp projection, never a file-only session or an identity assertion.
    @concurrent
    public func scanWithActivity(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFileOnlySessions: Bool,
        includeRolloutActivity: Bool) async -> ScanResult
    {
        let allProcesses = await self.processRecords(environment: environment)
        let processes = Array(AgentSessionCorrelation.newestProcessesFirst(
            AgentPSOutputParser.agentProcesses(from: allProcesses))
            .prefix(max(0, self.config.maxProcessCount)))
        let homeDirectory = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let readRolloutMetadata = includeFileOnlySessions || !includeRolloutActivity
        let trustedCodexAppServerPresent = readRolloutMetadata && AgentPSOutputParser.hasTrustedChatGPTCodexAppServer(
            in: allProcesses, validator: self.appServerTrustValidator)
        guard Self.shouldScanSessionMetadata(
            hasAgentProcesses: !processes.isEmpty,
            includeFileOnlySessions: includeFileOnlySessions,
            hasTrustedCodexAppServer: trustedCodexAppServerPresent) || includeRolloutActivity
        else { return ScanResult() }
        let codexAppServerPresent = AgentPSOutputParser.hasCodexAppServer(in: allProcesses) ||
            trustedCodexAppServerPresent
        let cwdByPID = await self.cwdByPID(processes.map(\.pid), environment: environment)
        let codexCWDs = processes.filter { AgentPSOutputParser.provider(for: $0) == .codex }
            .compactMap { cwdByPID[$0.pid] }
        let codexHomeDirectory = URL(
            fileURLWithPath: environment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path,
            isDirectory: true)
        let host = ProcessInfo.processInfo.hostName
        var directoryBudget = DirectoryMetadataScanBudget(
            maxEntryCount: self.config.maxDirectoryEntryCount,
            maxDepth: self.config.maxDirectoryDepth,
            timeLimit: includeFileOnlySessions
                ? self.config.directoryScanBudget
                : min(self.config.directoryScanBudget, self.config.adaptiveDirectoryScanBudget),
            startedAt: self.directoryScanStartedAt(),
            didVisitEntry: self.didVisitDirectoryEntry)
        var piFamilyDirectoryBudget = directoryBudget
        let piFamilySessions = PiFamilySessionScanner.scan(
            input: PiFamilySessionScanner.ScanInput(
                processes: processes,
                cwdByPID: cwdByPID,
                environment: environment,
                now: now,
                host: host,
                config: self.config),
            directoryBudget: &piFamilyDirectoryBudget)
        let includeUnmatchedCodexRollouts = includeFileOnlySessions || trustedCodexAppServerPresent
        let enrichRollouts = readRolloutMetadata && (includeUnmatchedCodexRollouts || !codexCWDs.isEmpty)
        var candidates = enrichRollouts ? self.codexRolloutCandidates(
            now: now, codexHomeDirectory: codexHomeDirectory, directoryBudget: &directoryBudget) : []
        let rollouts = enrichRollouts ? self.codexRollouts(
            candidates: candidates,
            matchingCWDs: includeUnmatchedCodexRollouts ? nil : codexCWDs,
            directoryBudget: &directoryBudget) : []
        let threadMetadata = rollouts.isEmpty ? [:] : Self.codexThreadMetadata(
            rollouts: rollouts,
            codexHomeDirectory: codexHomeDirectory,
            environment: environment)
        let sessions = self.sessions(
            processes: processes,
            cwdByPID: cwdByPID,
            rollouts: rollouts,
            context: ScanContext(
                homeDirectory: homeDirectory,
                host: host,
                now: now,
                codexAppServerPresent: codexAppServerPresent,
                includeUnmatchedCodexRollouts: includeUnmatchedCodexRollouts,
                threadMetadata: threadMetadata,
                piFamilySessions: piFamilySessions),
            directoryBudget: &directoryBudget)
        if includeRolloutActivity, !enrichRollouts {
            // Preserve the shared budget for process-backed Claude activity before the new file-only signal.
            candidates = self.codexRolloutCandidates(
                now: now, codexHomeDirectory: codexHomeDirectory, directoryBudget: &directoryBudget)
        }
        return ScanResult(
            sessions: sessions,
            latestRolloutActivityAt: includeRolloutActivity ? candidates.first?.modifiedAt : nil)
    }

    /// Returns the project directories of live Pi processes so historical cost scans can resolve
    /// project-level `.pi/settings.json` without assuming the app's own current directory.
    @concurrent
    public func piWorkingDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> [URL]
    {
        let contexts = await self.piSessionProcessContexts(environment: environment)
        var seen = Set<String>()
        return contexts.compactMap(\.workingDirectory).filter { seen.insert($0.path).inserted }
    }

    /// Returns the command selectors and project directories of live Pi-family processes so cost scans can
    /// resolve process-owned `--session-dir` and `--profile` choices alongside project settings.
    @concurrent
    public func piSessionProcessContexts(
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> [PiSessionProcessContext]
    {
        let allProcesses = await self.processRecords(environment: environment)
        // Provider-specific by design: only Pi processes provide project roots for Pi history resolution.
        // Keep every process through context resolution first so duplicate processes do not consume the
        // process budget before an older process with a distinct session root is considered.
        let processes = AgentSessionCorrelation.newestProcessesFirst(
            AgentPSOutputParser.agentProcesses(from: allProcesses)
                .filter { AgentPSOutputParser.provider(for: $0) == .pi })
        guard !processes.isEmpty, self.config.maxProcessCount > 0 else { return [] }

        let cwdByPID = await self.cwdByPID(processes.map(\.pid), environment: environment)
        var seen = Set<String>()
        let distinctContexts: [PiSessionProcessContext] = processes.compactMap { process in
            let workingDirectory = cwdByPID[process.pid]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            // Keep unresolved selectors so missing CWD evidence cannot turn unknown history into zero.
            let context = PiSessionProcessContext(
                command: process.command,
                arguments: process.arguments,
                workingDirectory: workingDirectory,
                selectorEnvironment: process.piSelectorEnvironment)
            let key = PiFamilySessionScanner.processRootSelectorKey(context)
            guard seen.insert(key).inserted else { return nil }
            return context
        }
        return distinctContexts
            .prefix(max(0, self.config.maxProcessCount))
            .sorted {
                $0.workingDirectory?.path == $1.workingDirectory?.path
                    ? $0.command < $1.command
                    : ($0.workingDirectory?.path ?? "<unresolved-cwd>") <
                    ($1.workingDirectory?.path ?? "<unresolved-cwd>")
            }
    }

    public static func shouldScanSessionMetadata(
        hasAgentProcesses: Bool,
        includeFileOnlySessions: Bool,
        hasTrustedCodexAppServer: Bool = false) -> Bool
    {
        hasAgentProcesses || includeFileOnlySessions || hasTrustedCodexAppServer
    }

    private static func codexThreadMetadata(
        rollouts: [Rollout],
        codexHomeDirectory: URL,
        environment: [String: String])
        -> [String: CodexThreadMetadata]
    {
        let sessionIDs = Set(rollouts.map(\.metadata.sessionID))
        let indexedNames = CodexThreadMetadataReader.indexedThreadNames(
            codexHomeDirectory: codexHomeDirectory,
            sessionIDs: sessionIDs)
        var groups: [String: (reader: CodexThreadMetadataReader, sessionIDs: Set<String>)] = [:]
        for rollout in rollouts {
            let resolvedWorkingDirectory = rollout.metadata.cwd.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }
            let reader = CodexThreadMetadataReader(
                codexHomeDirectory: codexHomeDirectory,
                environment: environment,
                resolvedWorkingDirectory: resolvedWorkingDirectory)
            let key = reader.databaseURL.path
            groups[key, default: (reader, [])].sessionIDs.insert(rollout.metadata.sessionID)
        }

        var metadata: [String: CodexThreadMetadata] = [:]
        for group in groups.values {
            metadata.merge(group.reader.metadata(for: group.sessionIDs, indexedNames: indexedNames)) { _, latest in
                latest
            }
        }
        return metadata
    }

    private func sessions(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        rollouts: [Rollout],
        context: ScanContext,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [AgentSession]
    {
        var sessions: [AgentSession] = []
        var matchedRolloutPaths = Set<String>()
        let claudeProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .claude }
        let claudeCWDs = Set(claudeProcesses.compactMap { cwdByPID[$0.pid] })
        var claudeTranscriptsByCWD: [String: [ClaudeSessionProjectMapper.Transcript]] = [:]
        for cwd in claudeCWDs {
            claudeTranscriptsByCWD[cwd] = ClaudeSessionProjectMapper.transcripts(
                cwd: cwd,
                homeDirectory: context.homeDirectory,
                limit: self.config.maxClaudeTranscriptCountPerProject,
                now: context.now,
                budget: &directoryBudget,
                clampModificationDate: self.futureModificationDateClamp.clamp)
        }
        let claudeTranscripts = AgentSessionCorrelation.assignClaudeTranscripts(
            processes: claudeProcesses,
            cwdByPID: cwdByPID,
            transcriptsByCWD: claudeTranscriptsByCWD)
        let codexProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .codex }
        let codexDescriptiveNamePIDs = AgentSessionCorrelation.unambiguousProcessIDs(
            processes: codexProcesses,
            cwdByPID: cwdByPID)

        for process in processes {
            // Pi-family processes are correlated by PiFamilySessionScanner.
            guard let provider = AgentPSOutputParser.provider(for: process), provider != .pi else { continue }
            let processCWD = cwdByPID[process.pid]
            let rollout = provider == .codex ? rollouts.first { candidate in
                !matchedRolloutPaths.contains(candidate.url.path) &&
                    AgentSessionCorrelation.codexWorkingDirectoriesMatch(candidate.metadata.cwd, processCWD)
            } : nil
            if let rollout { matchedRolloutPaths.insert(rollout.url.path) }
            let transcript = provider == .claude ? claudeTranscripts[process.pid] : nil
            let modifiedAt = rollout?.modifiedAt ?? transcript?.modifiedAt
            let cwd = processCWD ?? rollout?.metadata.cwd
            let rolloutSource = rollout?.metadata.sessionSource
            sessions.append(AgentSession(
                id: rollout?.metadata.sessionID ?? transcript?.url.deletingPathExtension().lastPathComponent ??
                    "pid:\(process.pid)",
                provider: provider,
                source: provider == .claude ? AgentPSOutputParser.source(for: process) :
                    (rolloutSource == .unknown ? nil : rolloutSource) ?? .cli,
                state: self.config.state(lastActivityAt: modifiedAt, now: context.now, hasLiveProcess: true),
                pid: process.pid,
                cwd: cwd,
                projectName: cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent },
                sessionName: codexDescriptiveNamePIDs.contains(process.pid)
                    ? rollout?.metadata.descriptiveName(
                        threadMetadata: rollout.flatMap { context.threadMetadata[$0.metadata.sessionID] })
                    : nil,
                startedAt: process.startedAt,
                lastActivityAt: modifiedAt,
                transcriptPath: rollout?.url.path ?? transcript?.url.path,
                host: context.host))
        }

        for rollout in rollouts
            where context.includeUnmatchedCodexRollouts &&
            !matchedRolloutPaths.contains(rollout.url.path)
        {
            guard var session = CodexRolloutFirstLineParser.makeSession(
                metadata: rollout.metadata,
                transcriptURL: rollout.url,
                modifiedAt: rollout.modifiedAt,
                host: context.host,
                config: self.config,
                now: context.now)
            else { continue }
            session.sessionName = rollout.metadata.descriptiveName(
                threadMetadata: context.threadMetadata[rollout.metadata.sessionID])
            session.source = AgentSessionCorrelation.fileOnlyCodexSource(
                metadataSource: session.source,
                appServerPresent: context.codexAppServerPresent)
            sessions.append(session)
        }
        sessions.append(contentsOf: context.piFamilySessions)

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

    private func processRecords(environment: [String: String]) async -> [AgentProcessRecord] {
        if let processOutputProvider = self.processOutputProvider {
            let records = await AgentPSOutputParser.parse(processOutputProvider(environment))
            guard let processEnvironmentProvider = self.processEnvironmentProvider else { return records }
            let piPIDs = records.filter { AgentPSOutputParser.piDialect(for: $0) != nil }.map(\.pid)
            guard !piPIDs.isEmpty else { return records }
            let environments = await processEnvironmentProvider(piPIDs)
            return records.map { record in
                guard AgentPSOutputParser.piDialect(for: record) != nil else { return record }
                return record.withPiSelectorEnvironment(environments[record.pid])
            }
        }
        #if canImport(Darwin)
        return DarwinProcessEnumerator.allPIDs().compactMap { pid in
            Self.darwinProcessRecord(pid: pid)
        }
        #else
        let records = await AgentPSOutputParser.parse(self.processOutput(environment: environment))
        #if os(Linux)
        return records.map { record in
            guard AgentPSOutputParser.piDialect(for: record) != nil else { return record }
            return record.withPiSelectorEnvironment(PiProcessEnvironment.readLinuxEnvironment(pid: record.pid))
        }
        #else
        return records
        #endif
        #endif
    }

    #if canImport(Darwin)
    /// Builds a process record from libproc data. `proc_pidpath` fails with ENOENT once an updater deletes the
    /// running binary (for example the old package directory after a Claude Code update), so argv is preferred
    /// and the executable path is only the fallback command when argv is unavailable.
    static func darwinProcessRecord(
        pid: Int32,
        bsdInfo: (Int32) -> (ppid: Int32, startTime: Date)? = DarwinProcessEnumerator.bsdInfo,
        processArguments: (Int32) -> (arguments: [String], piSelectorEnvironment: [String: String]?)? =
            DarwinProcessEnumerator.argumentsWithPiSelectorEnvironment,
        executablePath: (Int32) -> String? = DarwinProcessEnumerator.executablePath) -> AgentProcessRecord?
    {
        guard let bsdInfo = bsdInfo(pid) else { return nil }
        let processArguments = processArguments(pid)
        let arguments = processArguments?.arguments
        guard let command = arguments?.joined(separator: " ") ?? executablePath(pid) else { return nil }
        return AgentProcessRecord(
            pid: pid,
            ppid: bsdInfo.ppid,
            startedAt: bsdInfo.startTime,
            command: command,
            arguments: arguments,
            piSelectorEnvironment: processArguments?.piSelectorEnvironment)
    }
    #endif

    #if !canImport(Darwin)
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
    #endif

    private func cwdByPID(_ pids: [Int32], environment: [String: String]) async -> [Int32: String] {
        if let cwdProvider = self.cwdProvider { return await cwdProvider(pids, environment) }
        guard !pids.isEmpty else { return [:] }
        #if canImport(Darwin)
        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            DarwinProcessEnumerator.currentWorkingDirectory(pid: pid).map { (pid, $0) }
        })
        #else
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

        return Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            let path = "/proc/\(pid)/cwd"
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            return (pid, destination)
        })
        #endif
    }

    private func codexRolloutCandidates(
        now: Date,
        codexHomeDirectory: URL,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [RolloutCandidate]
    {
        let root = codexHomeDirectory.appendingPathComponent("sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap(\.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let fileManager = FileManager.default

        let candidates = days.flatMap { day -> [RolloutCandidate] in
            let directory = root.appendingPathComponent(formatter.string(from: day), isDirectory: true)
            let files = directoryBudget.files(in: directory, fileManager: fileManager)
            return directoryBudget.compactMapWhileTimeRemains(files) { file in
                guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl",
                      let modifiedAt = try? file.resourceValues(
                          forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (file, self.futureModificationDateClamp.clamp(
                    url: file,
                    modifiedAt: modifiedAt,
                    now: now))
            }
        }.sorted { $0.modifiedAt > $1.modifiedAt }
        return Array(candidates.prefix(max(0, self.config.maxCodexRolloutCount)))
    }

    private func codexRollouts(
        candidates: [RolloutCandidate],
        matchingCWDs: [String]?,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [Rollout]
    {
        var remainingCWDs = matchingCWDs ?? []
        var rollouts: [Rollout] = []
        for candidate in candidates {
            guard directoryBudget.hasTimeRemaining() else { break }
            guard let metadata = self.rolloutMetadataReader(candidate.url) else { continue }
            rollouts.append(Rollout(url: candidate.url, modifiedAt: candidate.modifiedAt, metadata: metadata))
            if let index = remainingCWDs.firstIndex(where: {
                AgentSessionCorrelation.codexWorkingDirectoriesMatch(metadata.cwd, $0)
            }) {
                remainingCWDs.remove(at: index)
                if matchingCWDs != nil, remainingCWDs.isEmpty {
                    break
                }
            }
        }
        return rollouts
    }

    private func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        return BinaryLocator.find(name, in: path.split(separator: ":").map(String.init), fileManager: .default)
    }
}
