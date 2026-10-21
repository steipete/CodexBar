import Foundation

/// Builds a replacement artifact without rewriting unchanged blocks on clone-capable volumes.
/// Only the private temporary file is modified; the caller still commits by atomic rename.
final class CostUsageClaudeArtifactWriter {
    private let descriptor: Int32
    private var offset: Int64 = 0
    private let usesClone: Bool
    private var comparison = [UInt8](repeating: 0, count: 64 * 1024)

    #if DEBUG
    @TaskLocal static var observeWrittenBytesForTesting: (@Sendable (Int) -> Void)?
    #endif

    init?(temporaryURL: URL, replacing url: URL) {
        var cloned = false
        #if os(macOS)
        let source = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if source >= 0 {
            defer { close(source) }
            // Pin the source inode so another atomic replacement cannot change what is cloned.
            var metadata = stat()
            if fstat(source, &metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
               metadata.st_mode & mode_t(S_IWUSR) != 0, metadata.st_flags == 0
            {
                cloned = fclonefileat(source, AT_FDCWD, temporaryURL.path, UInt32(CLONE_NOOWNERCOPY)) == 0
            }
        }
        #endif
        var descriptor: Int32 = -1
        if cloned {
            descriptor = open(temporaryURL.path, O_RDWR | O_NOFOLLOW)
            if descriptor < 0 || fchmod(descriptor, mode_t(0o600)) != 0 {
                if descriptor >= 0 { close(descriptor) }
                guard unlink(temporaryURL.path) == 0 else { return nil }
                cloned = false
            }
        }
        if !cloned {
            descriptor = open(temporaryURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
        self.usesClone = cloned
    }

    deinit { close(self.descriptor) }

    /// Returns bytes submitted to writes, including private temporary output.
    func append(_ data: Data) throws -> Int {
        try data.withUnsafeBytes { incoming in
            guard let base = incoming.baseAddress else { return 0 }
            var written = 0
            var consumed = 0
            while consumed < incoming.count {
                let count = min(self.comparison.count, incoming.count - consumed)
                let next = base.advanced(by: consumed)
                let equal = self.usesClone && self.comparison.withUnsafeMutableBytes { previous in
                    guard let previousBase = previous.baseAddress else { return false }
                    return pread(self.descriptor, previousBase, count, off_t(self.offset)) == count
                        && memcmp(previousBase, next, count) == 0
                }
                if !equal {
                    var remaining = count
                    while remaining > 0 {
                        let result = pwrite(
                            self.descriptor,
                            next.advanced(by: count - remaining),
                            remaining,
                            off_t(self.offset + Int64(count - remaining)))
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
                        remaining -= result
                        written += result
                    }
                }
                consumed += count
                self.offset += Int64(count)
            }
            #if DEBUG
            Self.observeWrittenBytesForTesting?(written)
            #endif
            return written
        }
    }

    func finish() throws {
        // Clones may contain a longer previous artifact; never retain its old suffix.
        guard ftruncate(self.descriptor, off_t(self.offset)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
