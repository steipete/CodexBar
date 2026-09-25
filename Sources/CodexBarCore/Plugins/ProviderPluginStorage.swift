import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Non-secret, instance-scoped state. Every operation reloads under a process-shared lock.
final class ProviderPluginStorage: @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        var values: [String: String]
    }

    static var defaultDirectory: URL {
        CodexBarConfigStore.defaultURL().deletingLastPathComponent().appendingPathComponent("plugin-storage")
    }

    private let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var retired = false

    init(directory: URL, instanceID: ProviderInstanceID) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(instanceID.rawValue + ".json")
    }

    func access(
        _ operation: String,
        key: any ProviderPluginValue,
        value: (any ProviderPluginValue)?) throws -> String?
    {
        guard key.isString else { throw ProviderPluginError.script("storage key must be a string") }
        let key = key.stringValue()
        guard !key.isEmpty, key.utf8.count <= 128 else {
            throw ProviderPluginError.script("storage key must contain 1-128 UTF-8 bytes")
        }
        return try self.withFileLock {
            guard !self.retired else { throw ProviderPluginError.script("plugin storage has been removed") }
            var values = try self.load()
            switch operation {
            case "get": return values[key]
            case "set":
                guard let value, value.isString else {
                    throw ProviderPluginError.script("storage value must be a string")
                }
                let text = value.stringValue()
                if values[key] == text { return nil }
                values[key] = text
            case "remove":
                guard values.removeValue(forKey: key) != nil else { return nil }
            default: throw ProviderPluginError.script("unknown storage operation")
            }
            try Self.validate(values)
            let data = try JSONEncoder().encode(Payload(version: 1, values: values))
            try data.write(to: self.fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
            return nil
        }
    }

    func removeAll() throws {
        try self.withFileLock {
            self.retired = true
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                try FileManager.default.removeItem(at: self.fileURL)
            }
        }
    }

    private static func validate(_ values: [String: String]) throws {
        guard values.count <= 64,
              values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 16384 }),
              values.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65536
        else { throw ProviderPluginError.script("storage exceeds its entry or UTF-8 byte limits") }
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return [:] }
        let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 400_000
        else { throw ProviderPluginError.script("invalid plugin storage file") }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: self.fileURL))
            guard payload.version == 1 else { throw ProviderPluginError.script("unsupported storage version") }
            try Self.validate(payload.values)
            return payload.values
        } catch {
            throw ProviderPluginError.script("invalid or incompatible plugin storage")
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try self.lock.withLock {
            try FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(
                self.fileURL.appendingPathExtension("lock").path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK,
                0o600)
            guard descriptor >= 0 else { throw ProviderPluginError.script("plugin storage lock is unavailable") }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw ProviderPluginError.script("invalid plugin storage lock")
            }
            // Never block the engine on a competing process or an abandoned writer.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw ProviderPluginError.script("plugin storage is busy")
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }
}
