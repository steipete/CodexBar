#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

enum CodexRemoteLogStorage {
    static let markerName = "ownership"
    static let lockName = "active.lock"

    final class Request: @unchecked Sendable {
        let url: URL
        let descriptor: Int32

        init(url: URL, descriptor: Int32) {
            self.url = url
            self.descriptor = descriptor
        }

        deinit { close(self.descriptor) }
    }

    static func attributes(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CodexRemoteLogError.localStorage }
        return value
    }

    static func isDirectory(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    static func isRegular(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }

    static func privateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw CodexRemoteLogError.localStorage }
        let value = try self.attributes(url)
        guard self.isDirectory(value), value.st_uid == getuid(), value.st_mode & 0o777 == 0o700 else {
            throw CodexRemoteLogError.localStorage
        }
    }

    static func privateFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CodexRemoteLogError.localStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() } catch { throw CodexRemoteLogError.localStorage }
    }

    static func create(root: URL) throws -> Request {
        try self.privateDirectory(root)
        let name = "request-" + UUID().uuidString
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else { throw CodexRemoteLogError.localStorage }
        do {
            let descriptor = open(
                url.appendingPathComponent(self.lockName).path,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600)
            guard descriptor >= 0 else { throw CodexRemoteLogError.localStorage }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw CodexRemoteLogError.localStorage
            }
            let request = Request(url: url, descriptor: descriptor)
            try self.privateFile(Data(self.marker(name: name).utf8), at: url.appendingPathComponent(self.markerName))
            return request
        } catch {
            do { try FileManager.default.removeItem(at: url) } catch { throw CodexRemoteLogError.cleanupFailed }
            throw error
        }
    }

    static func marker(name: String) -> String { "CodexBar SSH logs v1\n\(getuid())\n\(name)\n" }

    static func removeRequest(_ url: URL) throws {
        // Preserve the ownership proof throughout recursive raw/scan-cache deletion. A crash during
        // payload cleanup therefore leaves an identifiable request, not unmarked private content.
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for child in children where ![self.markerName, self.lockName].contains(child.lastPathComponent) {
            try FileManager.default.removeItem(at: child)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A final metadata-only deletion failure must remain retryable where storage is writable.
            if FileManager.default.fileExists(atPath: url.path) {
                let marker = url.appendingPathComponent(self.markerName)
                let lock = url.appendingPathComponent(self.lockName)
                if !FileManager.default.fileExists(atPath: marker.path) {
                    try? self.privateFile(Data(self.marker(name: url.lastPathComponent).utf8), at: marker)
                }
                if !FileManager.default.fileExists(atPath: lock.path) { try? self.privateFile(Data(), at: lock) }
            }
            throw CodexRemoteLogError.cleanupFailed
        }
    }

    /// Only an exact UUID, owner/mode, marker and nonblocking lock authorize orphan deletion.
    static func abandoned(_ url: URL) -> Request? {
        let name = url.lastPathComponent
        guard name.hasPrefix("request-"), UUID(uuidString: String(name.dropFirst(8))) != nil,
              let directory = try? self.attributes(url), self.isDirectory(directory),
              directory.st_uid == getuid(), directory.st_mode & 0o777 == 0o700
        else { return nil }
        let markerURL = url.appendingPathComponent(self.markerName)
        guard let marker = try? self.attributes(markerURL), self.isRegular(marker),
              marker.st_uid == getuid(), marker.st_mode & 0o777 == 0o600, marker.st_size < 256,
              (try? String(contentsOf: markerURL, encoding: .utf8)) == self.marker(name: name)
        else { return nil }
        let descriptor = open(url.appendingPathComponent(self.lockName).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var lockAttributes = stat()
        guard fstat(descriptor, &lockAttributes) == 0, self.isRegular(lockAttributes),
              lockAttributes.st_uid == getuid(), lockAttributes.st_mode & 0o777 == 0o600,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { close(descriptor); return nil }
        return Request(url: url, descriptor: descriptor)
    }

    static func verifyTree(_ root: URL, limits: CodexRemoteLogMirror.Limits) throws -> [String: Int64] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in false })
        else { throw CodexRemoteLogError.localStorage }
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let normalized = url.standardizedFileURL
            guard normalized.path.hasPrefix(canonicalRoot.path + "/") else { throw CodexRemoteLogError.unsafePath }
            let value: stat
            do { value = try self.attributes(url) } catch {
                // rsync renames a completed temporary file between directory enumeration and lstat.
                if errno == ENOENT { continue }
                throw error
            }
            guard value.st_uid == getuid() else { throw CodexRemoteLogError.localStorage }
            if self.isDirectory(value) {
                guard value.st_mode & 0o777 == 0o700 else { throw CodexRemoteLogError.localStorage }
            } else {
                guard self.isRegular(value), value.st_nlink == 1, value.st_mode & 0o777 == 0o600 else {
                    throw CodexRemoteLogError.unsafePath
                }
                let size = Int64(value.st_size)
                guard size >= 0, size <= limits.fileBytes, size <= limits.totalBytes - total,
                      sizes.count < limits.fileCount
                else { throw CodexRemoteLogError.budgetExceeded }
                total += size
                let relative = String(normalized.path.dropFirst(canonicalRoot.path.count + 1))
                sizes[relative] = size
            }
        }
        return sizes
    }
}
