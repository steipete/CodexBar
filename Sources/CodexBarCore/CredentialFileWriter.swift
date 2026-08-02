#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Writes credential-bearing files (session tokens, cookies) with owner-only (`0600`) permissions
/// established **before** any bytes are written, then atomically published — the same secure shape
/// `CodexOAuthCredentials` already uses. Also repairs the mode of a pre-existing file so users who
/// upgrade from a build that wrote `0644` are corrected on first access.
enum CredentialFileWriter {
    /// Atomically write `data` to `url` as an owner-only (`0600`) file. The bytes are written to a
    /// staged temp file created with `O_EXCL|O_CREAT` at mode `0600` (so the credential is never
    /// world-readable, even momentarily), fsync'd, then atomically `rename(2)`d over `url`.
    ///
    /// Throws on any failure and leaves no partial file — callers may `try?` this and rely on it
    /// failing closed (no insecure file is published) rather than leaving a `0644` file behind.
    ///
    /// `beforePublish` runs against the staged (already `0600`) file after the bytes are written and
    /// before the atomic rename, for callers that need to validate or post-process before publishing.
    static func writePrivate(
        _ data: Data,
        to url: URL,
        beforePublish: ((URL) throws -> Void)? = nil) throws
    {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let staged = directory.appendingPathComponent(
            ".\(url.lastPathComponent).codexbar-staged-\(UUID().uuidString)", isDirectory: false)
        let descriptor = staged.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.posixError(errno, path: staged.path) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var handleOpen = true
        do {
            // Belt-and-braces: force 0600 even if umask or a permissive O_CREAT mode widened it.
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw Self.posixError(errno, path: staged.path) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            handleOpen = false

            try beforePublish?(staged)

            // Atomic publish: rename(2) replaces any existing destination in one step.
            let renamed = staged.path.withCString { src in
                url.path.withCString { dst in rename(src, dst) }
            }
            guard renamed == 0 else { throw Self.posixError(errno, path: url.path) }
        } catch {
            if handleOpen { try? handle.close() }
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// If `url` exists and is readable by group or others, restrict it to `0600`. Best-effort;
    /// used to remediate credential files created `0644` by earlier builds when they are next read.
    static func repairPermissions(at url: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              (mode & 0o077) != 0
        else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func posixError(_ code: Int32, path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ])
    }
}
