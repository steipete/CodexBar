import Foundation

public struct RemoteCodexCostSource: Codable, Sendable, Equatable, Identifiable {
    public static let defaultID = "default"
    public static let defaultRemoteCodexHome = "~/.codex"
    public static let defaultSyncTimeoutSeconds = 300

    public var id: String
    public var enabled: Bool?
    public var label: String?
    public var sshTarget: String?
    public var sshPort: Int?
    public var remoteCodexHome: String?
    public var syncTimeoutSeconds: Int?

    public init(
        id: String = Self.defaultID,
        enabled: Bool? = true,
        label: String? = nil,
        sshTarget: String? = nil,
        sshPort: Int? = nil,
        remoteCodexHome: String? = nil,
        syncTimeoutSeconds: Int? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.label = label
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.remoteCodexHome = remoteCodexHome
        self.syncTimeoutSeconds = syncTimeoutSeconds
    }

    public var isEnabled: Bool {
        self.enabled ?? true
    }

    public var sanitizedID: String {
        let trimmed = self.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? Self.defaultID : trimmed
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = source.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return sanitized.isEmpty ? Self.defaultID : sanitized
    }

    public var sanitizedLabel: String? {
        Self.clean(self.label)
    }

    public var displayLabel: String {
        self.sanitizedLabel
            ?? self.sanitizedSSHTarget
            ?? self.sanitizedID
    }

    public var connectionDescription: String {
        let target = self.sanitizedSSHTarget ?? self.displayLabel
        let port = self.sshPort.flatMap { $0 > 0 ? $0 : nil }.map { " (port \($0))" } ?? ""
        return "\(target)\(port): \(self.sanitizedRemoteCodexHome)"
    }

    public var sanitizedSSHTarget: String? {
        Self.clean(self.sshTarget)
    }

    public var sanitizedRemoteCodexHome: String {
        Self.clean(self.remoteCodexHome) ?? Self.defaultRemoteCodexHome
    }

    public var boundedSyncTimeout: TimeInterval {
        let raw = self.syncTimeoutSeconds ?? Self.defaultSyncTimeoutSeconds
        return TimeInterval(max(5, min(600, raw)))
    }

    public var normalized: RemoteCodexCostSource {
        RemoteCodexCostSource(
            id: self.sanitizedID,
            enabled: self.isEnabled,
            label: self.sanitizedLabel,
            sshTarget: self.sanitizedSSHTarget,
            sshPort: self.sshPort.flatMap { $0 > 0 ? $0 : nil },
            remoteCodexHome: self.sanitizedRemoteCodexHome,
            syncTimeoutSeconds: Int(self.boundedSyncTimeout))
    }

    public var signature: String {
        let port = self.sshPort.map(String.init) ?? ""
        return [
            self.sanitizedID,
            self.isEnabled ? "1" : "0",
            self.sanitizedLabel ?? "",
            self.sanitizedSSHTarget ?? "",
            port,
            self.sanitizedRemoteCodexHome,
            "\(Int(self.boundedSyncTimeout))",
        ].joined(separator: "|")
    }

    public static func enabled(_ sources: [RemoteCodexCostSource]) -> [RemoteCodexCostSource] {
        sources
            .map(\.normalized)
            .filter { $0.isEnabled && $0.sanitizedSSHTarget != nil }
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct RemoteCodexCostMirror: Sendable, Equatable {
    public let sourceID: String
    public let label: String
    public let codexHomeMirror: URL
    public let scanCacheRoot: URL

    public init(sourceID: String, label: String, codexHomeMirror: URL, scanCacheRoot: URL) {
        self.sourceID = sourceID
        self.label = label
        self.codexHomeMirror = codexHomeMirror
        self.scanCacheRoot = scanCacheRoot
    }
}

public struct RemoteCodexCostSyncWindow: Sendable, Equatable {
    public let since: Date
    public let until: Date

    public init(since: Date, until: Date) {
        self.since = since
        self.until = until
    }
}

public enum RemoteCodexCostSyncError: LocalizedError, Sendable {
    case missingRsync
    case invalidSSHTarget(String)
    case syncFailed(source: String, details: String)

    public var errorDescription: String? {
        switch self {
        case .missingRsync:
            "Remote Codex cost sync requires /usr/bin/rsync."
        case let .invalidSSHTarget(target):
            "Invalid remote Codex SSH target: \(target). Use a Host alias or user@host; put ports in the port field."
        case let .syncFailed(source, details):
            "Remote Codex cost sync failed for \(source): \(details)"
        }
    }
}

public struct RemoteCodexCostSyncer: Sendable {
    private static let rsyncBinary = "/usr/bin/rsync"
    private static let sshBinary = "/usr/bin/ssh"

    private let cacheRoot: URL?

    public init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot
    }

    public func syncEnabledSources(
        _ sources: [RemoteCodexCostSource],
        window: RemoteCodexCostSyncWindow? = nil) async throws -> [RemoteCodexCostMirror]
    {
        let enabled = RemoteCodexCostSource.enabled(sources)
        guard !enabled.isEmpty else { return [] }
        guard FileManager.default.isExecutableFile(atPath: Self.rsyncBinary) else {
            throw RemoteCodexCostSyncError.missingRsync
        }

        var mirrors: [RemoteCodexCostMirror] = []
        for (index, source) in enabled.enumerated() {
            try Task.checkCancellation()
            let mirror = try await self.sync(source: source, index: index, window: window)
            mirrors.append(mirror)
        }
        return mirrors
    }

    private func sync(
        source: RemoteCodexCostSource,
        index: Int,
        window: RemoteCodexCostSyncWindow?) async throws -> RemoteCodexCostMirror
    {
        guard let target = source.sanitizedSSHTarget else {
            throw RemoteCodexCostSyncError.invalidSSHTarget(source.displayLabel)
        }
        guard Self.isValidSSHTarget(target) else {
            throw RemoteCodexCostSyncError.invalidSSHTarget(target)
        }

        let root = self.remoteSourceRoot(source: source, index: index)
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        let scanCache = root.appendingPathComponent("scan-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try await self.syncDirectory(DirectorySyncRequest(
            source: source,
            target: target,
            component: "sessions",
            destination: mirror.appendingPathComponent("sessions", isDirectory: true),
            window: window,
            required: true))
        try await self.syncDirectory(DirectorySyncRequest(
            source: source,
            target: target,
            component: "archived_sessions",
            destination: mirror.appendingPathComponent("archived_sessions", isDirectory: true),
            window: window,
            required: false))
        return RemoteCodexCostMirror(
            sourceID: source.sanitizedID,
            label: source.displayLabel,
            codexHomeMirror: mirror,
            scanCacheRoot: scanCache)
    }

    private struct DirectorySyncRequest {
        var source: RemoteCodexCostSource
        var target: String
        var component: String
        var destination: URL
        var window: RemoteCodexCostSyncWindow?
        var required: Bool
    }

    private func syncDirectory(_ request: DirectorySyncRequest) async throws {
        let remoteRoot = Self.trimTrailingSlashes(request.source.sanitizedRemoteCodexHome)
        let remotePath = Self.escapeRemoteShellPath("\(remoteRoot)/\(request.component)")
        let remote = "\(request.target):\(remotePath)/"
        let sshCommand = Self.sshCommand(for: request.source)
        let list = try await self.remoteJSONLList(request, remotePath: remotePath)
        try Self.resetDirectory(request.destination)
        guard !list.isEmpty else { return }

        let listFile = request.destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(request.component)-files-from", isDirectory: false)
        try (list.joined(separator: "\n") + "\n").write(to: listFile, atomically: true, encoding: .utf8)

        let args = [
            "-az",
            "--prune-empty-dirs",
            "--files-from=\(listFile.path)",
            "-e", sshCommand,
            remote,
            "\(request.destination.path)/",
        ]

        do {
            _ = try await SubprocessRunner.run(
                binary: Self.rsyncBinary,
                arguments: args,
                environment: ProcessInfo.processInfo.environment,
                timeout: request.source.boundedSyncTimeout,
                label: "remote-codex-cost-\(request.component)-\(request.source.sanitizedID)")
        } catch let error as SubprocessRunnerError {
            if !request.required, Self.isMissingRemoteDirectory(error) { return }
            throw RemoteCodexCostSyncError.syncFailed(
                source: request.source.connectionDescription,
                details: error.localizedDescription)
        } catch {
            throw RemoteCodexCostSyncError.syncFailed(
                source: request.source.connectionDescription,
                details: error.localizedDescription)
        }
    }

    private func remoteJSONLList(_ request: DirectorySyncRequest, remotePath: String) async throws -> [String] {
        let missingExit = request.required ? "23" : "0"
        let command = [
            "if [ -d \(remotePath) ]; then",
            "cd \(remotePath) && find . -type f -name '*.jsonl' -print;",
            "else exit \(missingExit); fi",
        ].joined(separator: " ")
        let args = Self.sshArguments(for: request.source) + [request.target, command]

        do {
            let result = try await SubprocessRunner.run(
                binary: Self.sshBinary,
                arguments: args,
                environment: ProcessInfo.processInfo.environment,
                timeout: min(60, request.source.boundedSyncTimeout),
                label: "remote-codex-cost-list-\(request.component)-\(request.source.sanitizedID)")
            return Self.filteredRelativeJSONLPaths(result.stdout, window: request.window)
        } catch let error as SubprocessRunnerError {
            if !request.required, Self.isMissingRemoteDirectory(error) { return [] }
            throw RemoteCodexCostSyncError.syncFailed(
                source: request.source.connectionDescription,
                details: error.localizedDescription)
        } catch {
            throw RemoteCodexCostSyncError.syncFailed(
                source: request.source.connectionDescription,
                details: error.localizedDescription)
        }
    }

    private func remoteSourceRoot(source: RemoteCodexCostSource, index: Int) -> URL {
        let root = self.cacheRoot ?? Self.defaultCacheRoot()
        let id = source.sanitizedID
        let suffix = index == 0 ? id : "\(id)-\(index)"
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("remote-codex", isDirectory: true)
            .appendingPathComponent(suffix, isDirectory: true)
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    private static func sshCommand(for source: RemoteCodexCostSource) -> String {
        let args = [Self.sshBinary] + Self.sshArguments(for: source)
        return args.map(Self.shellQuote).joined(separator: " ")
    }

    private static func sshArguments(for source: RemoteCodexCostSource) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        if let port = source.sshPort, port > 0 {
            args.append(contentsOf: ["-p", "\(port)"])
        }
        return args
    }

    private static func shellQuote(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func isValidSSHTarget(_ target: String) -> Bool {
        guard !target.isEmpty else { return false }
        guard !target.hasPrefix("-") else { return false }
        guard target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        guard !target.contains(":") else { return false }
        return true
    }

    static func resetDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value.isEmpty ? RemoteCodexCostSource.defaultRemoteCodexHome : value
    }

    private static func escapeRemoteShellPath(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-~")
        var out = ""
        for scalar in path.unicodeScalars {
            if safe.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("\\")
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isMissingRemoteDirectory(_ error: SubprocessRunnerError) -> Bool {
        guard case let .nonZeroExit(_, stderr) = error else { return false }
        let lower = stderr.lowercased()
        return lower.contains("no such file")
            || lower.contains("not found")
            || lower.contains("change_dir")
            || lower.contains("missing remote directory")
    }

    static func filteredRelativeJSONLPaths(
        _ stdout: String,
        window: RemoteCodexCostSyncWindow?) -> [String]
    {
        let sinceKey = window.map { Self.dayKey(from: $0.since) }
        let untilKey = window.map { Self.dayKey(from: $0.until) }
        return stdout
            .split(whereSeparator: \.isNewline)
            .map { raw in
                var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("./") {
                    path.removeFirst(2)
                }
                return path
            }
            .filter { path in
                guard path.lowercased().hasSuffix(".jsonl") else { return false }
                guard let sinceKey, let untilKey, let pathKey = Self.firstDayKey(in: path) else {
                    return true
                }
                return pathKey >= sinceKey && pathKey <= untilKey
            }
            .sorted()
    }

    private static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1)
    }

    private static let dayKeyRegex = try? NSRegularExpression(
        pattern: "(\\d{4})[-/](\\d{2})[-/](\\d{2})")

    private static func firstDayKey(in text: String) -> String? {
        guard let regex = self.dayKeyRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let year = Range(match.range(at: 1), in: text),
              let month = Range(match.range(at: 2), in: text),
              let day = Range(match.range(at: 3), in: text)
        else {
            return nil
        }
        return "\(text[year])-\(text[month])-\(text[day])"
    }
}
