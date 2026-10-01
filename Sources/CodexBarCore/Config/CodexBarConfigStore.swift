import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CodexBarConfigStoreError: LocalizedError {
    case invalidURL
    case decodeFailed(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid CodexBar config path."
        case let .decodeFailed(details):
            "Failed to decode CodexBar config: \(details)"
        case let .encodeFailed(details):
            "Failed to encode CodexBar config: \(details)"
        }
    }
}

public struct CodexBarConfigStore: @unchecked Sendable {
    public static let pathEnvironmentKey = "CODEXBAR_CONFIG"
    public static let xdgConfigHomeEnvironmentKey = "XDG_CONFIG_HOME"

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> CodexBarConfig? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        let data = try Data(contentsOf: self.fileURL)
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return nil }
        do {
            return try CodexBarConfig.decode(from: data).normalized()
        } catch {
            throw CodexBarConfigStoreError.decodeFailed(error.localizedDescription)
        }
    }

    public func loadOrCreateDefault() throws -> CodexBarConfig {
        if let existing = try self.load() {
            return existing
        }
        let config = CodexBarConfig.makeDefault()
        try self.save(config)
        return config
    }

    public func save(_ config: CodexBarConfig) throws {
        let data = try self.encodedData(for: config)
        try self.saveEncodedData(data)
    }

    public func encodedData(for config: CodexBarConfig) throws -> Data {
        do {
            return try config.normalized().encodedData()
        } catch {
            throw CodexBarConfigStoreError.encodeFailed(error.localizedDescription)
        }
    }

    public func saveEncodedData(_ data: Data) throws {
        try self.withWriteLock {
            try CredentialFileWriter.writePrivate(data, to: self.fileURL)
        }
    }

    /// Best-effort refreshes must compare and publish under the same lock as ordinary config writes.
    /// Skip contention rather than delaying an interactive writer or publishing a stale credential.
    package func updateIfAvailable(_ update: (inout CodexBarConfig) throws -> Bool) throws {
        try self.withWriteLock(wait: false) {
            guard var config = try self.load(), try update(&config) else { return }
            try CredentialFileWriter.writePrivate(self.encodedData(for: config), to: self.fileURL)
        }
    }

    public func deleteIfPresent() throws {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        try self.withWriteLock {
            if self.fileManager.fileExists(atPath: self.fileURL.path) {
                try self.fileManager.removeItem(at: self.fileURL)
            }
        }
    }

    private func withWriteLock(wait: Bool = true, _ body: () throws -> Void) throws {
        try self.fileManager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Keep this inode: unlinking the lock could give simultaneous writers different locks.
        let descriptor = open(
            self.fileURL.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == geteuid()
        else { throw POSIXError(.EINVAL) }
        while flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            if errno == EINTR { continue }
            if !wait, errno == EWOULDBLOCK { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try body()
    }

    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        if let override = environment[pathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }

        if let xdgConfigHome = environment[xdgConfigHomeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !xdgConfigHome.isEmpty
        {
            let expanded = (xdgConfigHome as NSString).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent("codexbar", isDirectory: true)
                    .appendingPathComponent("config.json")
            }
        }

        let xdgDefault = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: xdgDefault.path) {
            return xdgDefault
        }

        let legacy = home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }

        return xdgDefault
    }
}
