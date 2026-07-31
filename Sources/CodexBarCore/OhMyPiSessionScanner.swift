import Foundation

struct OhMyPiSessionRecord: Equatable, Sendable {
    let id: String
    let cwd: String?
    let sessionName: String?
    let startedAt: Date?
    let modifiedAt: Date
    let url: URL
}

enum OhMyPiSessionFileParser {
    private static let maximumReadSize = 16 * 1024

    static func parse(url: URL, modifiedAt: Date, now: Date) -> OhMyPiSessionRecord? {
        guard let data = readPrefix(from: url),
              let lines = completeLines(in: data)
        else { return nil }

        var nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        var titleSlotWasPresent = false
        var titleSlot: String?
        if let first = Self.jsonObject(from: nonEmptyLines[0]),
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

        let rawTitle = titleSlotWasPresent ? titleSlot : header["title"] as? String
        let sessionName = rawTitle.flatMap(Self.sanitizedTitle)
        let startedAt = (header["timestamp"] as? String).flatMap(Self.parseDate)

        return OhMyPiSessionRecord(
            id: id,
            cwd: header["cwd"] as? String,
            sessionName: sessionName,
            startedAt: startedAt,
            modifiedAt: min(modifiedAt, now),
            url: url)
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

struct OhMyPiSessionRootResolver: Sendable {
    static func sessionRoots(
        environment: [String: String],
        fileManager: FileManager = .default) -> [URL]
    {
        self.sessionRoots(
            environment: environment,
            baseDirectory: self.currentDirectory(fileManager: fileManager),
            fileManager: fileManager)
    }

    static func sessionRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [URL]
    {
        guard let profile = activeProfile(in: environment) else {
            // `nil` is the valid default profile. An invalid profile is
            // represented separately so a malformed environment fails closed.
            guard self.profileValueIsValid(in: environment) else { return [] }
            return self.defaultProfileRoots(
                environment: environment,
                baseDirectory: baseDirectory,
                fileManager: fileManager)
        }

        return Self.namedProfileRoots(
            profile: profile,
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    static func defaultProfileSessionRoots(
        environment: [String: String],
        fileManager: FileManager = .default) -> [URL]
    {
        self.defaultProfileSessionRoots(
            environment: environment,
            baseDirectory: self.currentDirectory(fileManager: fileManager),
            fileManager: fileManager)
    }

    static func defaultProfileSessionRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [URL]
    {
        self.defaultProfileRoots(
            environment: self.sanitizedDefaultEnvironment(environment),
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    private static func defaultProfileRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> [URL]
    {
        guard let home = homeURL(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return [] }
        guard let configRoot = Self.configRoot(home: home, environment: environment) else { return [] }
        let customAgentRoot = Self.customAgentRoot(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        let agentRoot: URL
        if let customAgentRoot {
            agentRoot = customAgentRoot
        } else {
            guard let canonicalAgentRoot = Self.canonicalAgentRoot(
                configRoot.appendingPathComponent("agent", isDirectory: true),
                home: home)
            else { return [] }
            agentRoot = canonicalAgentRoot
        }

        guard let root = Self.sessionRoot(agentRoot: agentRoot, fileManager: fileManager) else { return [] }

        #if os(macOS) || os(Linux)
        if customAgentRoot == nil,
           let xdgDataHome = Self.environmentURL(
               environment["XDG_DATA_HOME"],
               baseDirectory: baseDirectory,
               fileManager: fileManager)
        {
            let xdgSessions = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(xdgSessions, fileManager: fileManager),
               let root = Self.sessionRoot(
                   agentRoot: xdgDataHome.appendingPathComponent("omp", isDirectory: true),
                   fileManager: fileManager)
            {
                return [root]
            }
        }
        #endif

        return [root]
    }

    private static func namedProfileRoots(
        profile: String,
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> [URL]
    {
        guard let home = homeURL(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return [] }
        guard let configRoot = Self.configRoot(home: home, environment: environment) else { return [] }
        let profileRoot = configRoot
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
        guard let agentRoot = Self.canonicalAgentRoot(
            profileRoot.appendingPathComponent("agent", isDirectory: true),
            home: home)
        else { return [] }

        guard let root = Self.sessionRoot(agentRoot: agentRoot, fileManager: fileManager) else { return [] }
        #if os(macOS) || os(Linux)
        if let xdgDataHome = Self.environmentURL(
            environment["XDG_DATA_HOME"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        {
            let xdgProfileRoot = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profile, isDirectory: true)
            let xdgSessions = xdgProfileRoot.appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(xdgSessions, fileManager: fileManager),
               let root = Self.sessionRoot(
                   agentRoot: xdgProfileRoot,
                   fileManager: fileManager)
            {
                return [root]
            }
        }
        #endif

        return [root]
    }

    private static func profileValueIsValid(in environment: [String: String]) -> Bool {
        let value = if let omp = environment["OMP_PROFILE"] {
            omp
        } else {
            environment["PI_PROFILE"]
        }
        if case .invalid = Self.normalizedProfile(value) {
            return false
        }
        return true
    }

    private static func activeProfile(in environment: [String: String]) -> String? {
        let value = if let omp = environment["OMP_PROFILE"] {
            omp
        } else {
            environment["PI_PROFILE"]
        }
        guard case let .named(profile) = Self.normalizedProfile(value) else { return nil }
        return profile
    }

    private enum ProfileValue {
        case `default`
        case named(String)
        case invalid
    }

    private static func normalizedProfile(_ value: String?) -> ProfileValue {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty || normalized == "default" {
            return .default
        }

        let scalars = Array(normalized.unicodeScalars)
        guard let first = scalars.first,
              scalars.count <= 64,
              Self.isASCIIAlphaNumeric(first),
              scalars.dropFirst().allSatisfy(Self.isProfileTailScalar),
              normalized != ".",
              normalized != "..",
              !normalized.hasSuffix("."),
              !Self.isWindowsReservedProfileName(normalized)
        else { return .invalid }

        return .named(normalized)
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isProfileTailScalar(_ scalar: Unicode.Scalar) -> Bool {
        self.isASCIIAlphaNumeric(scalar) ||
            scalar.value == 46 ||
            scalar.value == 95 ||
            scalar.value == 45
    }

    private static func isWindowsReservedProfileName(_ value: String) -> Bool {
        let uppercased = value.uppercased()
        let base = uppercased.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        switch base {
        case "CON", "PRN", "AUX", "NUL":
            return true
        default:
            return (base.hasPrefix("COM") || base.hasPrefix("LPT")) &&
                base.count == 4 &&
                base.last.map(\.isNumber) == true
        }
    }

    private static func homeURL(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        guard let home = environmentURL(
            environment["HOME"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return nil }
        return home
    }

    private static func configRoot(home: URL, environment: [String: String]) -> URL? {
        let name: String = if let configuredPath = environment["PI_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredPath.isEmpty
        {
            configuredPath
        } else {
            ".omp"
        }
        guard !name.hasPrefix("/") else { return nil }

        let canonicalHome = Self.canonicalURL(home)
        let configRoot = Self.canonicalURL(
            canonicalHome.appendingPathComponent(name, isDirectory: true))
        guard Self.isWithin(root: canonicalHome, candidate: configRoot) else { return nil }
        return configRoot
    }

    private static func customAgentRoot(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        self.environmentURL(
            environment["PI_CODING_AGENT_DIR"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    private static func environmentURL(
        _ value: String?,
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        guard let value else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard let baseDirectory else { return nil }
            url = baseDirectory.appendingPathComponent(path, isDirectory: true)
        }
        return Self.canonicalURL(url)
    }

    private static func sanitizedDefaultEnvironment(_ environment: [String: String]) -> [String: String] {
        // A process with an inaccessible environment must not inherit
        // process-specific config, custom roots, XDG roots, or profile
        // selectors from the scanner's ambient environment. HOME is the only
        // input needed to identify the standard default profile root.
        guard let home = environment["HOME"] else { return [:] }
        return ["HOME": home]
    }

    private static func currentDirectory(fileManager: FileManager) -> URL {
        URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    }

    private static func sessionRoot(agentRoot: URL, fileManager: FileManager) -> URL? {
        let canonicalAgentRoot = Self.canonicalURL(agentRoot)
        let candidate = Self.canonicalURL(
            agentRoot.appendingPathComponent("sessions", isDirectory: true))
        guard Self.isWithin(root: canonicalAgentRoot, candidate: candidate) else { return nil }
        return candidate
    }

    private static func canonicalAgentRoot(_ agentRoot: URL, home: URL) -> URL? {
        let canonicalHome = Self.canonicalURL(home)
        let canonicalAgentRoot = Self.canonicalURL(agentRoot)
        guard Self.isWithin(root: canonicalHome, candidate: canonicalAgentRoot) else { return nil }
        return canonicalAgentRoot
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue
    }

    fileprivate static func isWithin(root: URL, candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

struct OhMyPiSessionScanner: Sendable {
    struct ScanInput: Sendable {
        let processes: [AgentProcessRecord]
        let cwdByPID: [Int32: String]
        let environment: [String: String]
        let environmentByPID: [Int32: [String: String]]?
        let now: Date
        let host: String
        let config: SessionScanConfig

        init(
            processes: [AgentProcessRecord],
            cwdByPID: [Int32: String],
            environment: [String: String],
            environmentByPID: [Int32: [String: String]]? = nil,
            now: Date,
            host: String,
            config: SessionScanConfig)
        {
            self.processes = processes
            self.cwdByPID = cwdByPID
            self.environment = environment
            self.environmentByPID = environmentByPID
            self.now = now
            self.host = host
            self.config = config
        }
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
        let liveProcesses = Array(
            AgentSessionCorrelation.newestProcessesFirst(
                processes.filter { AgentPSOutputParser.provider(for: $0) == .ohMyPi })
                .prefix(max(0, config.maxProcessCount)))
        guard !liveProcesses.isEmpty else {
            // OhMyPi sessions are process-backed in the local scanner. Never
            // turn an old session file into a file-only AgentSession.
            return []
        }

        var recordsByRoot: [String: [OhMyPiSessionRecord]] = [:]
        var usedRecordURLs = Set<String>()
        var sessions: [AgentSession] = []

        for process in liveProcesses {
            let processCWD = cwdByPID[process.pid]
            let processStandardizedCWD = processCWD
                .flatMap { $0.isEmpty ? nil : Self.standardizedPath($0) }
            let processCWDURL = processCWD
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

            var record: OhMyPiSessionRecord?
            if let processStartedAt = process.startedAt,
               let processStandardizedCWD,
               let processCWDURL
            {
                let roots: [URL] = if let processEnvironments = input.environmentByPID,
                                      let processEnvironment = processEnvironments[process.pid],
                                      !processEnvironment.isEmpty
                {
                    OhMyPiSessionRootResolver.sessionRoots(
                        environment: processEnvironment,
                        baseDirectory: processCWDURL)
                } else if input.environmentByPID == nil {
                    OhMyPiSessionRootResolver.defaultProfileSessionRoots(
                        environment: input.environment,
                        baseDirectory: processCWDURL)
                } else {
                    []
                }

                for root in roots {
                    guard directoryBudget.hasTimeRemaining() else { break }
                    let canonicalRoot = Self.canonicalURL(root)
                    let rootKey = canonicalRoot.path
                    let rootRecords: [OhMyPiSessionRecord]
                    if let cached = recordsByRoot[rootKey] {
                        rootRecords = cached
                    } else {
                        let discovered = Self.records(
                            in: canonicalRoot,
                            now: now,
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

            sessions.append(AgentSession(
                id: id,
                provider: .ohMyPi,
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

    private static func records(
        in root: URL,
        now: Date,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [OhMyPiSessionRecord]
    {
        let fileManager = FileManager.default
        var records: [OhMyPiSessionRecord] = []
        let canonicalRoot = Self.canonicalURL(root)

        guard directoryBudget.hasTimeRemaining() else { return [] }
        let projectDirectories = directoryBudget
            .childDirectories(in: canonicalRoot, fileManager: fileManager)
            .map(Self.canonicalURL)
            .filter { OhMyPiSessionRootResolver.isWithin(root: canonicalRoot, candidate: $0) }
            .sorted { $0.path < $1.path }

        for projectDirectory in projectDirectories {
            guard directoryBudget.hasTimeRemaining() else { break }
            let files = directoryBudget
                .files(in: projectDirectory, fileManager: fileManager)
                .filter { $0.pathExtension == "jsonl" }
                .map(Self.canonicalURL)
                .filter { file in
                    OhMyPiSessionRootResolver.isWithin(root: canonicalRoot, candidate: file) &&
                        Self.isDirectFile(in: file, projectDirectory: projectDirectory)
                }
                .sorted { $0.path < $1.path }

            for file in files {
                guard directoryBudget.hasTimeRemaining() else { break }
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    let record = OhMyPiSessionFileParser.parse(
                        url: file,
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
