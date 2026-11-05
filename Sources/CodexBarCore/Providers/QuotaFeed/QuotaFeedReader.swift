import Foundation

struct QuotaFeedReader: Sendable {
    var readFile: @Sendable (String, Int) throws -> Data = { path, maximumBytes in
        try BoundedLocalFileReader.read(path: path, maximumBytes: maximumBytes)
    }

    func fetch(path: String?, now: Date = Date()) throws -> UsageSnapshot {
        guard let path = SettingsValue.cleaned(path), path.hasPrefix("/"), !path.contains("\0") else {
            throw QuotaFeedError.missingPath
        }
        let data: Data
        do {
            data = try self.readFile(path, QuotaFeedSnapshot.maximumBytes)
        } catch {
            throw QuotaFeedError.unreadableFile
        }
        return try QuotaFeedSnapshot.decode(data, now: now).usageSnapshot()
    }
}
