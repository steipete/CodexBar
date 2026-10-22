import Foundation

/// Identity of an idle WAL database: no `-wal` sidecar, plus the main file's size, modification
/// time, file system number, and 100-byte header. Nil when a `-wal` sidecar exists or the file
/// cannot be examined.
struct SQLiteIdleDatabaseState: Equatable {
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64
    let header: Data

    static func read(at url: URL) -> Self? {
        // SQLite places sidecars next to the resolved database file, not next to a symlink.
        let resolved = url.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath: resolved.path + "-wal"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: resolved)
        else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 100) else { return nil }
        return Self(size: size, modified: modified, fileNumber: fileNumber, header: header)
    }

    /// The `immutable=1` query parameter is only reachable through a URI filename.
    static func immutableURI(for url: URL) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "file:\(path)?immutable=1"
    }
}
