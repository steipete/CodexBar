import Foundation

struct OMPSessionRootResolver: Sendable {
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
        self.resolvedSessionRoots(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager).map(\.url)
    }

    static func resolvedSessionRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [OMPSessionResolvedRoot]
    {
        guard let profile = activeProfile(in: environment) else {
            // `nil` is the valid default profile. An invalid profile is
            // represented separately so a malformed environment fails closed.
            guard self.profileValueIsValid(in: environment) else { return [] }
            return self.defaultProfileRoots(
                environment: environment,
                baseDirectory: baseDirectory,
                fileManager: fileManager)
                .map { OMPSessionResolvedRoot(url: $0, layout: .projectDirectories) }
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

    /// A named OMP profile is rooted at HOME (and optionally an absolute XDG directory), so it
    /// can be resolved even when process CWD lookup is unavailable.
    static func canResolveNamedProfileWithoutWorkingDirectory(
        _ profile: String,
        environment: [String: String]) -> Bool
    {
        guard case .named = self.normalizedProfile(profile),
              let home = homeURL(
                  environment: environment,
                  baseDirectory: nil,
                  fileManager: .default),
              configRoot(home: home, environment: environment) != nil
        else { return false }

        for key in ["XDG_DATA_HOME", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"] {
            guard let value = environment[key] else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || trimmed.hasPrefix("/") else { return false }
        }
        return true
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

        var roots = [root]
        #if os(macOS) || os(Linux)
        if customAgentRoot == nil,
           let xdgDataHome = Self.xdgDataHome(
               environment: environment,
               home: home,
               baseDirectory: baseDirectory,
               fileManager: fileManager)
        {
            let xdgSessions = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(xdgSessions, fileManager: fileManager),
               let xdgRoot = Self.sessionRoot(
                   agentRoot: xdgDataHome.appendingPathComponent("omp", isDirectory: true),
                   fileManager: fileManager)
            {
                roots.append(xdgRoot)
            }
        }
        #endif

        var seen = Set<String>()
        return roots.filter { seen.insert(Self.canonicalURL($0).path).inserted }
    }

    private static func namedProfileRoots(
        profile: String,
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> [OMPSessionResolvedRoot]
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
        var roots: [OMPSessionResolvedRoot] = []

        func appendExistingLayouts(in profileRoot: URL) {
            let canonicalProfileRoot = Self.canonicalURL(profileRoot)
            let directRoot = canonicalProfileRoot.appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(directRoot, fileManager: fileManager) {
                roots.append(OMPSessionResolvedRoot(url: directRoot, layout: .direct))
            }
            let agentRoot = canonicalProfileRoot
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(agentRoot, fileManager: fileManager) {
                roots.append(OMPSessionResolvedRoot(url: agentRoot, layout: .projectDirectories))
            }
        }

        // A selected profile may use either the direct `profiles/<name>/sessions` layout or
        // the older `profiles/<name>/agent/sessions` layout. Keep both when present so a
        // profile migration cannot silently hide part of its history.
        appendExistingLayouts(in: profileRoot)
        #if os(macOS) || os(Linux)
        if let xdgDataHome = Self.xdgDataHome(
            environment: environment,
            home: home,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        {
            let xdgProfileRoot = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profile, isDirectory: true)
            appendExistingLayouts(in: xdgProfileRoot)
        }
        #endif

        if roots.isEmpty {
            // Preserve the historical missing-root signal for an explicitly selected profile.
            roots.append(OMPSessionResolvedRoot(url: root, layout: .projectDirectories))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert(Self.canonicalURL($0.url).path).inserted }
    }

    /// Returns the profile directories that belong to the validated OMP configuration.
    /// This keeps profile discovery aligned with `sessionRoots` when `PI_CONFIG_DIR` is customized.
    static func profileDiscoveryDirectories(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [URL]
    {
        guard let home = homeURL(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager),
            let configRoot = Self.configRoot(home: home, environment: environment)
        else { return [] }

        var directories = [configRoot.appendingPathComponent("profiles", isDirectory: true)]
        #if os(macOS) || os(Linux)
        if Self.customAgentRoot(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager) == nil,
            let xdgDataHome = Self.xdgDataHome(
                environment: environment,
                home: home,
                baseDirectory: baseDirectory,
                fileManager: fileManager)
        {
            directories.append(
                xdgDataHome
                    .appendingPathComponent("omp", isDirectory: true)
                    .appendingPathComponent("profiles", isDirectory: true))
        }
        #endif

        var seen = Set<String>()
        return directories.compactMap { directory in
            let canonical = Self.canonicalURL(directory)
            return seen.insert(canonical.path).inserted ? canonical : nil
        }
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

    private static func xdgDataHome(
        environment: [String: String],
        home: URL,
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        if let configured = environment["XDG_DATA_HOME"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return self.environmentURL(
                configured,
                baseDirectory: baseDirectory,
                fileManager: fileManager)
        }
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
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

    static func isWithin(root: URL, candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

/// Resolves the historical Pi-family roots used by cost and usage discovery.
public enum PiFamilySessionRootResolver {
    /// Returns resolved roots for Pi and OMP historical session stores.
    ///
    /// Unresolved placeholders are omitted so callers can use the result for read-only source detection.
    public static func costSessionRootURLs(
        environment: [String: String],
        baseDirectory: URL? = nil,
        processContexts: [PiSessionProcessContext] = []) -> [URL]
    {
        PiFamilySessionScanner.costSessionRoots(
            environment: environment,
            baseDirectories: baseDirectory.map { [$0] },
            processContexts: processContexts)
            .filter(\.resolutionIsComplete)
            .map(\.url)
    }
}
