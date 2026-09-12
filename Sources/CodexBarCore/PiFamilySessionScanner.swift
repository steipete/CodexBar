import Foundation

struct PiFamilySessionRecord: Equatable, Sendable {
    let id: String
    let cwd: String?
    let sessionName: String?
    let startedAt: Date?
    let modifiedAt: Date
    let url: URL
}

enum PiFamilySessionRootLayout: Hashable, Sendable {
    case projectDirectories
    case direct
}

struct OMPSessionResolvedRoot: Hashable, Sendable {
    let url: URL
    let layout: PiFamilySessionRootLayout
}

enum PiFamilySessionFileParser {
    private static let maximumReadSize = 16 * 1024

    static func parse(
        url: URL,
        dialect: AgentSession.Dialect,
        modifiedAt: Date,
        now: Date) -> PiFamilySessionRecord?
    {
        guard let data = readPrefix(from: url),
              let lines = completeLines(in: data)
        else { return nil }

        var nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        var titleSlotWasPresent = false
        var titleSlot: String?
        if dialect == .omp,
           let first = Self.jsonObject(from: nonEmptyLines[0]),
           first["type"] as? String == "title"
        {
            titleSlotWasPresent = true
            titleSlot = first["title"] as? String
            nonEmptyLines.removeFirst()
        }

        guard let headerData = nonEmptyLines.first,
              let header = Self.jsonObject(from: headerData),
              header["type"] as? String == "session",
              let id = header["id"] as? String
        else { return nil }
        // Provider-specific by design: Pi session files require the upstream v3 header contract.
        if dialect == .pi, header["version"] as? Int != 3 {
            return nil
        }

        let rawTitle = switch dialect {
        case .pi:
            Self.latestPiSessionName(in: url, prefixLines: nonEmptyLines)
        case .omp:
            titleSlotWasPresent ? titleSlot : header["title"] as? String
        }
        let sessionName = rawTitle.flatMap(Self.sanitizedTitle)
        let startedAt = (header["timestamp"] as? String).flatMap(Self.parseDate)

        return PiFamilySessionRecord(
            id: id,
            cwd: header["cwd"] as? String,
            sessionName: sessionName,
            startedAt: startedAt,
            modifiedAt: min(modifiedAt, now),
            url: url)
    }

    private static func latestPiSessionName(in url: URL, prefixLines: [Data]) -> String? {
        var latest = Self.latestPiSessionName(in: prefixLines)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return latest }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(Self.maximumReadSize) else { return latest }

        let tailReadSize = 64 * 1024
        let offset = size > UInt64(tailReadSize) ? size - UInt64(tailReadSize) : 0
        do {
            try handle.seek(toOffset: offset)
            guard let tail = try handle.read(upToCount: tailReadSize), !tail.isEmpty else { return latest }
            var lines: [Data] = []
            for line in [UInt8](tail).split(separator: 0x0A, omittingEmptySubsequences: true) {
                lines.append(Data(line))
            }
            if offset > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            latest = Self.latestPiSessionName(in: lines) ?? latest
        } catch {
            return latest
        }
        return latest
    }

    private static func latestPiSessionName(in lines: [Data]) -> String? {
        lines.reversed().compactMap { line -> String? in
            guard let entry = Self.jsonObject(from: line),
                  entry["type"] as? String == "session_info"
            else { return nil }
            return entry["name"] as? String
        }.first
    }

    private static func readPrefix(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Self.maximumReadSize)
    }

    private static func completeLines(in data: Data) -> [Data]? {
        var lines: [Data] = []
        var lineStart = data.startIndex

        for index in data.indices where data[index] == 0x0A {
            lines.append(data.subdata(in: lineStart..<index))
            lineStart = data.index(after: index)
        }

        // A line without its terminating newline is either a partial bounded
        // read or a truncated record. Do not attempt to parse it at the limit.
        if lineStart < data.endIndex, data.count < Self.maximumReadSize {
            lines.append(data.subdata(in: lineStart..<data.endIndex))
        }
        guard lineStart == data.endIndex || !lines.isEmpty else { return nil }
        return lines
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func sanitizedTitle(_ value: String) -> String? {
        var result = ""
        for scalar in value.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar),
                  !CharacterSet.newlines.contains(scalar)
            else { continue }
            guard result.unicodeScalars.count < 64 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? nil : result
    }
}

// swiftlint:disable:next type_body_length
struct PiFamilySessionScanner: Sendable {
    struct ScanInput: Sendable {
        let processes: [AgentProcessRecord]
        let cwdByPID: [Int32: String]
        let environment: [String: String]
        let now: Date
        let host: String
        let config: SessionScanConfig
    }

    private struct SessionRoot: Hashable, Sendable {
        let url: URL
        let layout: PiFamilySessionRootLayout
        let missingIsKnownEmpty: Bool
        let preserveAfterProcessExit: Bool
        /// Identifies a durable selector that can replace an older retained root.
        let retentionKey: String?

        init(
            url: URL,
            layout: PiFamilySessionRootLayout,
            missingIsKnownEmpty: Bool = false,
            preserveAfterProcessExit: Bool = false,
            retentionKey: String? = nil)
        {
            self.url = url
            self.layout = layout
            self.missingIsKnownEmpty = missingIsKnownEmpty
            self.preserveAfterProcessExit = preserveAfterProcessExit
            self.retentionKey = retentionKey
        }
    }

    private struct ProfileSessionRootResolution {
        let roots: [SessionRoot]
        let isComplete: Bool
    }

    private struct PiSessionRootResolution {
        let roots: [SessionRoot]
        let isComplete: Bool
    }

    private struct OMPSessionRootResolution {
        let roots: [SessionRoot]
        let profileDiscoveryIsComplete: Bool
    }

    struct CostSessionRoot: Hashable, Sendable {
        let url: URL
        let missingIsKnownEmpty: Bool
        let resolutionIsComplete: Bool
        let preserveAfterProcessExit: Bool
        let retentionKeys: Set<String>

        init(
            url: URL,
            missingIsKnownEmpty: Bool,
            resolutionIsComplete: Bool = true,
            preserveAfterProcessExit: Bool = false,
            retentionKey: String? = nil,
            retentionKeys: Set<String> = [])
        {
            self.url = url
            self.missingIsKnownEmpty = missingIsKnownEmpty
            self.resolutionIsComplete = resolutionIsComplete
            self.preserveAfterProcessExit = preserveAfterProcessExit
            self.retentionKeys = retentionKeys.union(retentionKey.map { [$0] } ?? [])
        }
    }

    enum RetainedSettingsRootResolution: Sendable {
        case resolved(url: URL, retentionKey: String)
        case removed
        case unavailable
    }

    static func scan(
        input: ScanInput,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [AgentSession]
    {
        let processes = input.processes
        let cwdByPID = input.cwdByPID
        let now = input.now
        let host = input.host
        let config = input.config
        // Provider-specific by design: Pi-family sessions are correlated only with Pi provider processes.
        let liveProcesses = Array(AgentSessionCorrelation.newestProcessesFirst(
            processes.filter { AgentPSOutputParser.provider(for: $0) == .pi })
            .prefix(max(0, config.maxProcessCount)))
        guard !liveProcesses.isEmpty else {
            // Pi-family sessions are process-backed in the local scanner. Never
            // turn an old session file into a file-only AgentSession.
            return []
        }

        var recordsByRoot: [String: [PiFamilySessionRecord]] = [:]
        var usedRecordURLs = Set<String>()
        var sessions: [AgentSession] = []

        for process in liveProcesses {
            guard let dialect = AgentPSOutputParser.piDialect(for: process) else { continue }
            let processCWD = cwdByPID[process.pid]
            let processStandardizedCWD = processCWD
                .flatMap { $0.isEmpty ? nil : Self.standardizedPath($0) }

            var record: PiFamilySessionRecord?
            if let processStartedAt = process.startedAt,
               let processStandardizedCWD,
               let processCWD
            {
                let roots = Self.sessionRoots(
                    for: process,
                    dialect: dialect,
                    cwd: processCWD,
                    environment: input.environment)
                for root in roots {
                    guard directoryBudget.hasTimeRemaining() else { break }
                    let canonicalRoot = Self.canonicalURL(root.url)
                    let rootKey = "\(dialect.rawValue):\(root.layout):\(canonicalRoot.path)"
                    let rootRecords: [PiFamilySessionRecord]
                    if let cached = recordsByRoot[rootKey] {
                        rootRecords = cached
                    } else {
                        let discovered = Self.records(
                            in: canonicalRoot,
                            now: now,
                            dialect: dialect,
                            layout: root.layout,
                            directoryBudget: &directoryBudget)
                        recordsByRoot[rootKey] = discovered
                        rootRecords = discovered
                    }

                    if let candidate = rootRecords.first(where: { candidate in
                        guard candidate.modifiedAt >= processStartedAt,
                              let recordCWD = candidate.cwd,
                              !recordCWD.isEmpty,
                              Self.standardizedPath(recordCWD) == processStandardizedCWD
                        else { return false }
                        return !usedRecordURLs.contains(Self.canonicalURL(candidate.url).path)
                    }) {
                        record = candidate
                        usedRecordURLs.insert(Self.canonicalURL(candidate.url).path)
                        break
                    }
                }
            }

            let cwd = processCWD ?? record?.cwd
            let id = record?.id ?? "pid:\(process.pid)"
            let startedAt = record?.startedAt ?? process.startedAt

            // Provider-specific by design: this branch emits a Pi-family AgentSession with its fixed provider identity.
            sessions.append(AgentSession(
                id: id,
                provider: .pi,
                dialect: dialect,
                source: .cli,
                state: config.state(
                    lastActivityAt: record?.modifiedAt,
                    now: now,
                    hasLiveProcess: true),
                pid: process.pid,
                cwd: cwd,
                projectName: Self.projectName(cwd),
                sessionName: record?.sessionName,
                startedAt: startedAt,
                lastActivityAt: record?.modifiedAt,
                transcriptPath: record?.url.path,
                host: host))
        }

        var seen = Set<String>()
        return sessions
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .active
                }
                let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
                let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return (lhs.pid ?? Int32.min) > (rhs.pid ?? Int32.min)
            }
            .filter { seen.insert("\($0.host):\($0.id)").inserted }
    }

    private static func sessionRoots(
        for process: AgentProcessRecord,
        dialect: AgentSession.Dialect,
        cwd: String,
        environment: [String: String]) -> [SessionRoot]
    {
        // Provider-specific by design: Pi and OMP use different on-disk session-root contracts.
        switch dialect {
        case .pi:
            self.piSessionRootResolution(
                process: process,
                cwd: cwd,
                environment: environment).roots
        case .omp:
            self.ompSessionRoots(process: process, cwd: cwd, environment: environment)
        }
    }

    /// Resolves the same Pi-family roots used by live-session discovery for historical cost scans.
    /// Keeping this in one resolver prevents the menu and cost surfaces from silently reading different stores.
    static func costSessionRoots(
        environment: [String: String],
        baseDirectory: URL? = nil) -> [CostSessionRoot]
    {
        self.costSessionRoots(
            environment: environment,
            baseDirectories: baseDirectory.map { [$0] })
    }

    /// Resolves historical roots for every known Pi project directory. Project-level Pi settings are
    /// relative to the process working directory, so a single app-wide current directory is not enough
    /// when several Pi processes are active in different projects.
    static func costSessionRoots(
        environment: [String: String],
        baseDirectories: [URL]? = nil,
        processContexts: [PiSessionProcessContext] = []) -> [CostSessionRoot]
    {
        var configuredCWDs = baseDirectories ?? []
        if !processContexts.isEmpty {
            // Live process roots augment the scanner's normal working directory so default and project history
            // remain visible after a process starts or exits.
            configuredCWDs.insert(
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                at: 0)
            configuredCWDs.append(contentsOf: processContexts.compactMap(\.workingDirectory))
        }
        let cwdURLs = (configuredCWDs.isEmpty ? [URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)] : configuredCWDs)
            .map(Self.canonicalURL)
        let uniqueCWDs = cwdURLs.reduce(into: [URL]()) { result, url in
            guard !result.contains(where: { $0.path == url.path }) else { return }
            result.append(url)
        }
        let defaultProcess = AgentProcessRecord(pid: 0, ppid: 0, startedAt: nil, command: "")
        let hasExplicitProcessProfile = Self.hasExplicitProcessProfile(in: processContexts)
        // Provider-specific by design: historical cost scans must resolve both Pi dialects through the shared root
        // resolver.
        let dialects: [AgentSession.Dialect] = [.pi, .omp]
        var output: [CostSessionRoot] = []
        var outputIndexByPath: [String: Int] = [:]

        func appendCostRoot(_ root: CostSessionRoot) {
            let canonical = Self.canonicalURL(root.url)
            let candidate = CostSessionRoot(
                url: canonical,
                missingIsKnownEmpty: root.missingIsKnownEmpty,
                resolutionIsComplete: root.resolutionIsComplete,
                preserveAfterProcessExit: root.preserveAfterProcessExit,
                retentionKeys: root.retentionKeys)
            guard let index = outputIndexByPath[canonical.path] else {
                outputIndexByPath[canonical.path] = output.count
                output.append(candidate)
                return
            }

            // A shared root can be discovered through both dialects. Preserve the strictest
            // availability contract and all durable provenance when those discoveries converge.
            let existing = output[index]
            output[index] = CostSessionRoot(
                url: canonical,
                missingIsKnownEmpty: existing.missingIsKnownEmpty && candidate.missingIsKnownEmpty,
                resolutionIsComplete: existing.resolutionIsComplete && candidate.resolutionIsComplete,
                preserveAfterProcessExit: existing.preserveAfterProcessExit || candidate.preserveAfterProcessExit,
                retentionKeys: existing.retentionKeys.union(candidate.retentionKeys))
        }

        for dialect in dialects {
            var roots: [SessionRoot] = []
            var rootResolutionIsComplete = true
            for context in processContexts {
                let process = AgentProcessRecord(
                    pid: 0,
                    ppid: 0,
                    startedAt: nil,
                    command: context.command,
                    arguments: context.arguments)
                guard AgentPSOutputParser.piDialect(for: process) == dialect else { continue }
                let contextCWD: String
                if let workingDirectory = context.workingDirectory {
                    contextCWD = workingDirectory.path
                } else {
                    // Absolute session directories and named OMP profiles are independent of CWD.
                    // Other selectors cannot be resolved safely after CWD discovery failed.
                    guard Self.hasCWDIndependentRootSelection(
                        in: process,
                        environment: environment)
                    else {
                        rootResolutionIsComplete = false
                        continue
                    }
                    contextCWD = "/"
                }
                let resolution: (roots: [SessionRoot], isComplete: Bool)
                switch dialect {
                // Provider-specific by design: this branch resolves the Pi dialect's session roots.
                case .pi:
                    let result = Self.piSessionRootResolution(
                        process: process,
                        cwd: contextCWD,
                        environment: environment,
                        preserveSettingsRoot: context.workingDirectory != nil)
                    resolution = (result.roots, result.isComplete)
                case .omp:
                    let result = Self.ompSessionRootResolution(
                        process: process,
                        cwd: contextCWD,
                        environment: environment,
                        suppressProfileDiscovery: hasExplicitProcessProfile)
                    resolution = (result.roots, result.profileDiscoveryIsComplete)
                }
                // A process-selected root is safe to retain after exit because the
                // selector is explicit. Roots reached only through the process's
                // working directory or inherited environment must be re-resolved on
                // the next scan, otherwise a stale project can remain attributed.
                let processRootIsRetained = Self.hasExplicitProcessRootSelection(
                    dialect: dialect,
                    processContexts: [context])
                roots.append(contentsOf: resolution.roots.map { root in
                    SessionRoot(
                        url: root.url,
                        layout: root.layout,
                        missingIsKnownEmpty: root.missingIsKnownEmpty,
                        preserveAfterProcessExit: root.preserveAfterProcessExit || processRootIsRetained,
                        retentionKey: root.retentionKey ?? Self.processRetentionKey(
                            dialect: dialect,
                            process: process,
                            cwd: contextCWD,
                            environment: environment))
                })
                rootResolutionIsComplete = rootResolutionIsComplete && resolution.isComplete
            }
            for cwdURL in uniqueCWDs {
                switch dialect {
                // Provider-specific by design: this branch resolves the Pi dialect's session roots.
                case .pi:
                    let resolution = Self.piSessionRootResolution(
                        process: defaultProcess,
                        cwd: cwdURL.path,
                        environment: environment,
                        preserveSettingsRoot: false)
                    roots.append(contentsOf: resolution.roots)
                    rootResolutionIsComplete = rootResolutionIsComplete && resolution.isComplete
                case .omp:
                    let resolution = Self.ompSessionRootResolution(
                        process: defaultProcess,
                        cwd: cwdURL.path,
                        environment: environment,
                        suppressProfileDiscovery: hasExplicitProcessProfile)
                    roots.append(contentsOf: resolution.roots)
                    rootResolutionIsComplete = rootResolutionIsComplete && resolution.profileDiscoveryIsComplete
                }
            }
            let hasExplicitSelection = Self.hasExplicitCostRootSelection(
                dialect: dialect,
                environment: environment) || Self.hasExplicitProcessRootSelection(
                dialect: dialect,
                processContexts: processContexts)
            if roots.isEmpty, hasExplicitSelection {
                appendCostRoot(CostSessionRoot(
                    url: Self.unresolvedCostSessionRoot(for: dialect),
                    missingIsKnownEmpty: false,
                    resolutionIsComplete: false))
                continue
            }
            for root in roots {
                let canonical = Self.canonicalURL(root.url)
                appendCostRoot(CostSessionRoot(
                    url: canonical,
                    missingIsKnownEmpty: root.missingIsKnownEmpty,
                    resolutionIsComplete: true,
                    preserveAfterProcessExit: root.preserveAfterProcessExit,
                    retentionKey: root.retentionKey))
            }
            if !rootResolutionIsComplete {
                let unresolved = Self.unresolvedCostSessionRoot(for: dialect)
                appendCostRoot(CostSessionRoot(
                    url: unresolved,
                    missingIsKnownEmpty: false,
                    resolutionIsComplete: false))
            }
        }
        return output
    }

    private static func hasExplicitProcessProfile(in contexts: [PiSessionProcessContext]) -> Bool {
        contexts.contains { context in
            let process = AgentProcessRecord(
                pid: 0,
                ppid: 0,
                startedAt: nil,
                command: context.command,
                arguments: context.arguments)
            return AgentPSOutputParser.piDialect(for: process) == .omp &&
                Self.commandLineValue(
                    "--profile",
                    in: process.command,
                    arguments: process.arguments) != nil
        }
    }

    private static func unresolvedCostSessionRoot(for dialect: AgentSession.Dialect) -> URL {
        // Keep an unresolved selection visible to the cost scanner without ever enumerating a
        // real directory. The completion flag is the source of truth; this path is only a stable
        // cache-key component and a defensive placeholder.
        URL(fileURLWithPath: "/.codexbar-unresolved-\(dialect.rawValue)", isDirectory: true)
    }

    private static func defaultCostSessionRoot(
        for dialect: AgentSession.Dialect,
        environment: [String: String]) -> URL?
    {
        guard let home = homeURL(environment) else { return nil }
        // Provider-specific by design: Pi and OMP keep their default histories under distinct home directories.
        let directory = dialect == .pi ? ".pi" : ".omp"
        return Self.canonicalURL(
            home
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true))
    }

    private static func hasExplicitCostRootSelection(
        dialect: AgentSession.Dialect,
        environment: [String: String]) -> Bool
    {
        // Provider-specific by design: these environment keys select Pi-family history roots rather than generic
        // policy.
        let keys: [String] = switch dialect {
        case .pi:
            ["PI_CODING_AGENT_SESSION_DIR", "PI_CODING_AGENT_DIR"]
        case .omp:
            [
                "PI_CODING_AGENT_SESSION_DIR",
                "PI_CONFIG_DIR",
                "PI_CODING_AGENT_DIR",
                "OMP_PROFILE",
                "PI_PROFILE",
            ]
        }
        return keys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasExplicitProcessRootSelection(
        dialect: AgentSession.Dialect,
        processContexts: [PiSessionProcessContext]) -> Bool
    {
        processContexts.contains { context in
            let process = AgentProcessRecord(
                pid: 0,
                ppid: 0,
                startedAt: nil,
                command: context.command,
                arguments: context.arguments)
            guard AgentPSOutputParser.piDialect(for: process) == dialect else { return false }
            return switch dialect {
            // Provider-specific by design: this branch checks selectors for the Pi dialect.
            case .pi:
                Self.commandLineValue(
                    "--session-dir",
                    in: context.command,
                    arguments: context.arguments) != nil
            case .omp:
                Self.commandLineValue(
                    "--session-dir",
                    in: context.command,
                    arguments: context.arguments) != nil ||
                    Self.commandLineValue(
                        "--profile",
                        in: context.command,
                        arguments: context.arguments) != nil
            }
        }
    }

    /// Returns whether a process can resolve its session store without a working directory.
    /// Absolute (or home-relative) session directories and validated named OMP profiles have
    /// enough information to resolve from HOME alone.
    static func hasCWDIndependentRootSelection(
        in process: AgentProcessRecord,
        environment: [String: String]) -> Bool
    {
        if self.hasAbsoluteSessionDirectorySelector(in: process, environment: environment) {
            return true
        }
        guard AgentPSOutputParser.piDialect(for: process) == .omp,
              let profile = commandLineValue(
                  "--profile",
                  in: process.command,
                  arguments: process.arguments)
        else { return false }
        return OMPSessionRootResolver.canResolveNamedProfileWithoutWorkingDirectory(
            profile,
            environment: environment)
    }

    static func hasAbsoluteSessionDirectorySelector(
        in process: AgentProcessRecord,
        environment: [String: String]) -> Bool
    {
        guard let value = commandLineValue(
            "--session-dir",
            in: process.command,
            arguments: process.arguments)
        else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else { return false }
        return Self.pathURL(value, cwd: "/", home: environment["HOME"]) != nil
    }

    static func processRootSelectorKey(_ context: PiSessionProcessContext) -> String {
        let process = AgentProcessRecord(
            pid: 0, ppid: 0, startedAt: nil, command: context.command, arguments: context.arguments)
        let dialect = AgentPSOutputParser.piDialect(for: process)?.rawValue ?? "unknown"
        // Model, prompt and presentation arguments do not select another history store.
        let sessionDirectory = Self.commandLineValue(
            "--session-dir", in: context.command, arguments: context.arguments)
        let profile = Self.commandLineValue("--profile", in: context.command, arguments: context.arguments)
        return [
            dialect,
            context.workingDirectory?.standardizedFileURL.path ?? "<unresolved-cwd>",
            sessionDirectory ?? "<default-session-dir>",
            profile ?? "<default-profile>",
        ].joined(separator: "\u{1F}")
    }

    private static func processRetentionKey(
        dialect: AgentSession.Dialect,
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String]) -> String?
    {
        if let selector = commandLineValue(
            "--session-dir",
            in: process.command,
            arguments: process.arguments),
            let url = pathURL(selector, cwd: cwd, home: environment["HOME"])
        {
            return "process:" + dialect.rawValue + ":session-dir:" + url.path
        }
        if dialect == .omp,
           let profile = Self.commandLineValue(
               "--profile",
               in: process.command,
               arguments: process.arguments)
        {
            return "process:omp:profile:" + profile
        }
        return nil
    }

    private static func settingsRetentionKey(
        _ settingsURL: URL,
        sessionDirectory: String,
        resolvingDirectory: String) -> String
    {
        let trimmed = sessionDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectorIsCWDIndependent = trimmed.hasPrefix("/") ||
            trimmed == "~" ||
            trimmed.hasPrefix("~/")
        let base = if selectorIsCWDIndependent {
            ""
        } else {
            ":base=" + self.canonicalURL(URL(fileURLWithPath: resolvingDirectory, isDirectory: true)).path
        }
        return "settings:" + self.canonicalURL(settingsURL).path + base
    }

    static func retainedSettingsRootResolution(
        retentionKey: String,
        environment: [String: String]) -> RetainedSettingsRootResolution
    {
        let prefix = "settings:"
        guard retentionKey.hasPrefix(prefix) else { return .unavailable }
        let payload = String(retentionKey.dropFirst(prefix.count))
        guard !payload.isEmpty else { return .unavailable }

        let baseMarker = ":base="
        let settingsPath: String
        let resolvingDirectory: String?
        if let baseRange = payload.range(of: baseMarker, options: .backwards) {
            settingsPath = String(payload[..<baseRange.lowerBound])
            let base = String(payload[baseRange.upperBound...])
            resolvingDirectory = base.isEmpty ? nil : base
        } else {
            settingsPath = payload
            resolvingDirectory = Self.inferredSettingsResolvingDirectory(
                for: URL(fileURLWithPath: settingsPath, isDirectory: false))
        }
        guard settingsPath.hasPrefix("/") else { return .unavailable }

        let settingsURL = URL(fileURLWithPath: settingsPath, isDirectory: false)
        switch Self.sessionDirectoryResolution(in: settingsURL) {
        case .missing, .noSessionDirectory:
            return .removed
        case .unavailable:
            return .unavailable
        case let .configured(sessionDirectory):
            let trimmed = sessionDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectorIsCWDIndependent = trimmed.hasPrefix("/") ||
                trimmed == "~" ||
                trimmed.hasPrefix("~/")
            guard let resolvingDirectory = resolvingDirectory ??
                (selectorIsCWDIndependent ? "/" : nil)
            else {
                // A legacy global relative selector had no project provenance. Retain its old root
                // as unresolved rather than guessing which process directory originally resolved it.
                return .unavailable
            }
            guard let home = Self.homeURL(environment),
                  let url = Self.pathURL(
                      sessionDirectory,
                      cwd: resolvingDirectory,
                      home: home.path)
            else {
                return .unavailable
            }
            return .resolved(
                url: Self.canonicalURL(url),
                retentionKey: Self.settingsRetentionKey(
                    settingsURL,
                    sessionDirectory: sessionDirectory,
                    resolvingDirectory: resolvingDirectory))
        }
    }

    private static func inferredSettingsResolvingDirectory(for settingsURL: URL) -> String? {
        let parent = settingsURL.deletingLastPathComponent()
        // Provider-specific by design: only Pi project settings use the `.pi/settings.json` path.
        guard parent.lastPathComponent == ".pi" else { return nil }
        let grandparent = parent.deletingLastPathComponent()
        // Project settings live at <project>/.pi/settings.json. Global settings use the
        // separate <home>/.pi/agent/settings.json layout and never reach this helper.
        return self.canonicalURL(grandparent).path
    }

    private static func ompSessionRoots(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String]) -> [SessionRoot]
    {
        self.ompSessionRootResolution(process: process, cwd: cwd, environment: environment).roots
    }

    private static func ompSessionRootResolution(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String],
        suppressProfileDiscovery: Bool = false) -> OMPSessionRootResolution
    {
        let processHasExplicitSelection = Self.commandLineValue(
            "--session-dir",
            in: process.command,
            arguments: process.arguments) != nil || Self.commandLineValue(
            "--profile",
            in: process.command,
            arguments: process.arguments) != nil
        if let explicit = commandLineValue(
            "--session-dir",
            in: process.command,
            arguments: process.arguments),
            let url = pathURL(explicit, cwd: cwd, home: environment["HOME"])
        {
            return OMPSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                profileDiscoveryIsComplete: true)
        }
        if let configured = environment["PI_CODING_AGENT_SESSION_DIR"],
           let url = pathURL(configured, cwd: cwd, home: environment["HOME"])
        {
            return OMPSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                profileDiscoveryIsComplete: true)
        }

        guard let home = homeURL(environment) else {
            return OMPSessionRootResolution(roots: [], profileDiscoveryIsComplete: false)
        }
        var safeEnvironment = ["HOME": home.path]
        for key in [
            "PI_CONFIG_DIR",
            "PI_CODING_AGENT_DIR",
            "XDG_DATA_HOME",
            "OMP_PROFILE",
            "PI_PROFILE",
        ] {
            safeEnvironment[key] = environment[key]
        }
        if suppressProfileDiscovery,
           safeEnvironment["OMP_PROFILE"] == nil,
           safeEnvironment["PI_PROFILE"] == nil
        {
            // A live named profile is authoritative for this scan. Keep the ambient default root,
            // but do not broaden it to unrelated profiles discovered on disk.
            safeEnvironment["OMP_PROFILE"] = "default"
        }
        if let profile = Self.commandLineValue(
            "--profile",
            in: process.command,
            arguments: process.arguments)
        {
            safeEnvironment["OMP_PROFILE"] = profile
        }

        let baseDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
        var resolvedRoots = OMPSessionRootResolver.resolvedSessionRoots(
            environment: safeEnvironment,
            baseDirectory: baseDirectory).map { root in
            let canonical = Self.canonicalURL(root.url)
            let defaultRootIsKnownEmpty = !processHasExplicitSelection &&
                !Self.hasExplicitCostRootSelection(dialect: .omp, environment: environment) &&
                Self.defaultCostSessionRoot(for: .omp, environment: environment) == canonical
            return SessionRoot(
                url: canonical,
                layout: root.layout,
                missingIsKnownEmpty: defaultRootIsKnownEmpty)
        }
        var profileDiscoveryIsComplete = true

        if safeEnvironment["OMP_PROFILE"] == nil,
           safeEnvironment["PI_PROFILE"] == nil
        {
            let profileParents = OMPSessionRootResolver.profileDiscoveryDirectories(
                environment: safeEnvironment,
                baseDirectory: baseDirectory)
            for parent in profileParents {
                let resolution = Self.profileSessionRoots(in: parent)
                resolvedRoots.append(contentsOf: resolution.roots)
                profileDiscoveryIsComplete = profileDiscoveryIsComplete && resolution.isComplete
            }
        }

        var seen = Set<String>()
        let roots: [SessionRoot] = resolvedRoots.compactMap { root in
            let canonical = Self.canonicalURL(root.url)
            guard seen.insert(canonical.path).inserted else { return nil }
            return SessionRoot(
                url: canonical,
                layout: root.layout,
                missingIsKnownEmpty: root.missingIsKnownEmpty,
                preserveAfterProcessExit: root.preserveAfterProcessExit,
                retentionKey: root.retentionKey)
        }
        return OMPSessionRootResolution(
            roots: roots,
            profileDiscoveryIsComplete: profileDiscoveryIsComplete)
    }

    private static func piSessionRootResolution(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String],
        preserveSettingsRoot: Bool = false) -> PiSessionRootResolution
    {
        if let explicit = commandLineValue(
            "--session-dir",
            in: process.command,
            arguments: process.arguments)
        {
            guard let url = pathURL(explicit, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                isComplete: true)
        }
        if let configured = environment["PI_CODING_AGENT_SESSION_DIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let url = pathURL(configured, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                isComplete: true)
        }
        if let agentDirectory = environment["PI_CODING_AGENT_DIR"],
           !agentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let agentRoot = pathURL(agentDirectory, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(
                    url: agentRoot.appendingPathComponent("sessions", isDirectory: true),
                    layout: .projectDirectories)],
                isComplete: true)
        }

        guard let home = Self.homeURL(environment) else {
            return PiSessionRootResolution(roots: [], isComplete: false)
        }
        // Provider-specific by design: Pi's settings paths are distinct from OMP's profile roots.
        let globalSettings = home
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
        let projectSettings = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")

        let configured: (value: String, retentionKey: String)?
        switch Self.sessionDirectoryResolution(in: projectSettings) {
        case let .configured(value):
            configured = (
                value,
                Self.settingsRetentionKey(
                    projectSettings,
                    sessionDirectory: value,
                    resolvingDirectory: cwd))
        case .unavailable:
            return PiSessionRootResolution(roots: [], isComplete: false)
        case .missing, .noSessionDirectory:
            switch Self.sessionDirectoryResolution(in: globalSettings) {
            case let .configured(value):
                configured = (
                    value,
                    Self.settingsRetentionKey(
                        globalSettings,
                        sessionDirectory: value,
                        resolvingDirectory: cwd))
            case .unavailable:
                return PiSessionRootResolution(roots: [], isComplete: false)
            case .missing, .noSessionDirectory:
                configured = nil
            }
        }

        if let configured {
            guard let url = Self.pathURL(configured.value, cwd: cwd, home: home.path) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(
                    url: url,
                    layout: .direct,
                    preserveAfterProcessExit: preserveSettingsRoot,
                    retentionKey: configured.retentionKey)],
                isComplete: true)
        }

        // Provider-specific by design: this path is Pi's default project session directory.
        return PiSessionRootResolution(
            roots: [SessionRoot(
                url: home
                    .appendingPathComponent(".pi", isDirectory: true)
                    .appendingPathComponent("agent", isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true),
                layout: .projectDirectories,
                missingIsKnownEmpty: true)],
            isComplete: true)
    }

    private enum ProfileDirectoryInspection {
        case missing
        case notDirectory
        case readableDirectory
        case unavailable
    }

    private static func profileDirectoryInspection(_ url: URL) -> ProfileDirectoryInspection {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .notDirectory }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return .unavailable
        }
        return .readableDirectory
    }

    private static func profileSessionRoots(in profilesDirectory: URL) -> ProfileSessionRootResolution {
        switch self.profileDirectoryInspection(profilesDirectory) {
        case .missing:
            return ProfileSessionRootResolution(roots: [], isComplete: true)
        case .notDirectory, .unavailable:
            return ProfileSessionRootResolution(roots: [], isComplete: false)
        case .readableDirectory:
            break
        }

        let profiles: [URL]
        do {
            profiles = try FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            return ProfileSessionRootResolution(roots: [], isComplete: false)
        }

        var roots: [SessionRoot] = []
        var isComplete = true
        let canonicalProfilesDirectory = Self.canonicalURL(profilesDirectory)
        for profile in profiles {
            guard roots.count < 64 else {
                isComplete = false
                break
            }
            let canonicalProfile = Self.canonicalURL(profile)
            guard OMPSessionRootResolver.isWithin(
                root: canonicalProfilesDirectory,
                candidate: canonicalProfile)
            else { continue }
            switch Self.profileDirectoryInspection(canonicalProfile) {
            case .missing, .notDirectory:
                continue
            case .unavailable:
                isComplete = false
                continue
            case .readableDirectory:
                break
            }
            let xdgLayout = canonicalProfile.appendingPathComponent("sessions", isDirectory: true)
            switch Self.profileDirectoryInspection(xdgLayout) {
            case .readableDirectory:
                roots.append(SessionRoot(url: xdgLayout, layout: .direct))
            case .unavailable:
                isComplete = false
            case .missing, .notDirectory:
                break
            }
            let agentLayout = canonicalProfile
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            switch Self.profileDirectoryInspection(agentLayout) {
            case .readableDirectory:
                roots.append(SessionRoot(url: agentLayout, layout: .projectDirectories))
            case .unavailable:
                isComplete = false
            case .missing, .notDirectory:
                break
            }
        }
        return ProfileSessionRootResolution(
            roots: roots.sorted { $0.url.path < $1.url.path },
            isComplete: isComplete)
    }

    private enum PiSettingsSessionDirectoryResolution {
        case missing
        case noSessionDirectory
        case configured(String)
        case unavailable
    }

    private static func sessionDirectoryResolution(in settingsURL: URL) -> PiSettingsSessionDirectoryResolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: settingsURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard !isDirectory.boolValue,
              let values = try? settingsURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= 1024 * 1024,
              let data = try? Data(contentsOf: settingsURL, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unavailable
        }
        guard let rawValue = object["sessionDir"] else { return .noSessionDirectory }
        guard let sessionDir = rawValue as? String,
              !sessionDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unavailable
        }
        return .configured(sessionDir)
    }

    private static func commandLineValue(
        _ flag: String,
        in command: String,
        arguments: [String]? = nil) -> String?
    {
        let tokens = arguments ?? command.split(whereSeparator: \ .isWhitespace).map(String.init)
        for index in tokens.indices {
            if tokens[index] == flag, index + 1 < tokens.count {
                let value = tokens[index + 1]
                return value.hasPrefix("-") ? nil : value
            }
            let prefix = flag + "="
            if tokens[index].hasPrefix(prefix) {
                let value = String(tokens[index].dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func pathURL(_ path: String, cwd: String, home: String?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String = if trimmed == "~", let home {
            home
        } else if trimmed.hasPrefix("~/"), let home {
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true).path
        } else {
            trimmed
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    private static func homeURL(_ environment: [String: String]) -> URL? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func records(
        in root: URL,
        now: Date,
        dialect: AgentSession.Dialect,
        layout: PiFamilySessionRootLayout,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [PiFamilySessionRecord]
    {
        let fileManager = FileManager.default
        var records: [PiFamilySessionRecord] = []
        let canonicalRoot = Self.canonicalURL(root)

        guard directoryBudget.hasTimeRemaining() else { return [] }
        let projectDirectories: [URL]
        switch layout {
        case .direct:
            projectDirectories = [canonicalRoot]
        case .projectDirectories:
            let directories = directoryBudget.childDirectories(in: canonicalRoot, fileManager: fileManager)
            projectDirectories = directoryBudget.compactMapWhileTimeRemains(directories) { directory in
                let canonical = Self.canonicalURL(directory)
                return OMPSessionRootResolver.isWithin(root: canonicalRoot, candidate: canonical) ? canonical : nil
            }.sorted { $0.path < $1.path }
        }

        for projectDirectory in projectDirectories {
            guard directoryBudget.hasTimeRemaining() else { break }
            let entries = directoryBudget.files(in: projectDirectory, fileManager: fileManager)
            let files = directoryBudget.compactMapWhileTimeRemains(entries) { entry -> URL? in
                guard entry.pathExtension == "jsonl" else { return nil }
                let file = Self.canonicalURL(entry)
                guard OMPSessionRootResolver.isWithin(root: canonicalRoot, candidate: file),
                      Self.isDirectFile(in: file, projectDirectory: projectDirectory)
                else { return nil }
                return file
            }.sorted { $0.path < $1.path }

            for file in files {
                guard directoryBudget.hasTimeRemaining() else { break }
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    let record = PiFamilySessionFileParser.parse(
                        url: file,
                        dialect: dialect,
                        modifiedAt: modifiedAt,
                        now: now)
                else { continue }
                records.append(record)
            }
        }

        var seenURLs = Set<String>()
        var seenIDs = Set<String>()
        return records
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.url.path < rhs.url.path
            }
            .filter {
                seenURLs.insert(Self.canonicalURL($0.url).path).inserted &&
                    seenIDs.insert($0.id).inserted
            }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).standardizedFileURL.lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDirectFile(in file: URL, projectDirectory: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL.path == projectDirectory.path
    }
}
