import Darwin
import Foundation

enum WarpTerminalConfig {
    static let marker = "# CodexBar temporary terminal launch\n"
    static let lifetime: TimeInterval = 60

    struct Candidate {
        let url: URL
        let inode: ino_t
        let modifiedAt: Date
    }

    static func write(_ data: Data, temporaryURL: URL, configURL: URL) throws {
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Only this attempt's exclusive creation grants ownership of the temporary path.
        defer { _ = temporaryURL.path.withCString { unlink($0) } }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            try FileManager.default.moveItem(at: temporaryURL, to: configURL)
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func candidates(in directory: URL) -> [Candidate] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(self.candidate(at:))
    }

    static func candidate(at url: URL) -> Candidate? {
        guard url.lastPathComponent.range(
            of: #"^(codexbar_[0-9a-f]{32}\.toml|\.codexbar_[0-9a-f]{32}\.toml\.tmp)$"#,
            options: .regularExpression) != nil
        else { return nil }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              let prefix = try? handle.read(upToCount: self.marker.utf8.count),
              prefix == Data(self.marker.utf8)
        else { return nil }
        return Candidate(
            url: url,
            inode: info.st_ino,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    static func remove(_ candidate: Candidate) {
        var info = stat()
        guard candidate.url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_ino == candidate.inode
        else { return }
        // unlink cannot recursively remove a directory or follow a replacement symlink.
        _ = candidate.url.path.withCString { unlink($0) }
    }
}
