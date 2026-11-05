import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Host-side file access for explicit, user-selected data feeds. Reads only regular files and never follows the final
/// symlink.
enum BoundedLocalFileReader {
    enum ReadError: Error { case unreadable, tooLarge }

    static func read(path: String, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw ReadError.tooLarge }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReadError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else { throw ReadError.unreadable }
        guard status.st_size <= maximumBytes else { throw ReadError.tooLarge }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        return data
    }
}
