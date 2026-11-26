import Crypto
import Foundation

/// Only metadata and a digest of the boundary survive a scan. No transcript bytes enter the memo.
struct ClaudeAppendBoundary: Codable, Equatable {
    let digest: Data
    let endsAtNewline: Bool

    static func read(_ url: URL, size: Int64) throws -> Self {
        guard size >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let count = Int(min(size, 4096))
        try file.seek(toOffset: UInt64(size - Int64(count)))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return Self(digest: Data(SHA256.hash(data: data)), endsAtNewline: data.last == 10)
    }
}

/// Keep ignored appends in memory. A billable event, a cold launch or the replay limit returns
/// to the durable checkpoint. The report and its on-disk source certificate always agree.
final class ClaudeIgnoredAppends: @unchecked Sendable {
    private struct Cursor {
        let stamp: CostUsageClaudeFileStamp
        let boundary: ClaudeAppendBoundary
    }

    private let lock = NSLock()
    private var cursors: [String: Cursor] = [:]

    func matches(
        _ inventory: [String: CostUsageClaudeFileStamp],
        entry: CostUsageClaudeReportMemo.Entry,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Bool
    {
        guard inventory.count == entry.sourceInventory.count else { return false }
        var next = self.lock.withLock { self.cursors }
        for (path, stamp) in inventory where stamp != entry.sourceInventory[path] {
            try checkCancellation?()
            guard let baseline = entry.sourceInventory[path], baseline.fileID == stamp.fileID, baseline.size >= 0,
                  stamp.size > baseline.size, stamp.size - baseline.size <= 8 * 1024 * 1024,
                  let boundary = entry.appendBoundaries[path], boundary.endsAtNewline
            else { return false }
            let cursor = next[path] ?? Cursor(stamp: baseline, boundary: boundary)
            if cursor.stamp == stamp { continue }
            let url = URL(fileURLWithPath: path)
            guard stamp.size > cursor.stamp.size,
                  try cursor.stamp == baseline || ClaudeAppendBoundary.read(url, size: baseline.size) == boundary,
                  try ClaudeAppendBoundary.read(url, size: cursor.stamp.size) == cursor.boundary
            else { return false }
            var candidate = false
            let offset = try CostUsageJsonl.scan(
                fileURL: url,
                offset: cursor.stamp.size,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024,
                maxBytesToRead: stamp.size - cursor.stamp.size,
                checkCancellation: checkCancellation,
                onLine: { if CostUsageScanner.isClaudeUsageCandidate($0) { candidate = true } })
            guard !candidate, offset == stamp.size else { return false }
            let end = try ClaudeAppendBoundary.read(url, size: stamp.size)
            guard end.endsAtNewline, try CostUsageClaudeFileStamp.readIfPresent(at: url) == stamp else { return false }
            next[path] = Cursor(stamp: stamp, boundary: end)
        }
        self.lock.withLock { self.cursors = next }
        return true
    }
}
