import Foundation

/// Appends `AdaptiveRefreshTraceRecord`s to a JSONL file, one record per line. Best-effort by
/// design (mirrors `FileLogSink` in `CodexBarCore`'s logging stack): a trace recorder must never
/// be able to crash or block the app it's instrumenting, so every failure here is swallowed.
/// Serializes writes onto a private queue so calls from multiple call sites (decision, menu-open,
/// refresh-completed) never interleave partial lines.
public final class AdaptiveRefreshTraceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.steipete.codexbar.adaptivereplay.tracewriter", qos: .utility)
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private var fileURL: URL
    private var fileHandle: FileHandle?

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func currentURL() -> URL {
        self.queue.sync { self.fileURL }
    }

    public func append(_ record: AdaptiveRefreshTraceRecord) {
        self.queue.async {
            guard let data = try? self.encoder.encode(record) else { return }
            guard let handle = self.openHandleIfNeeded() else { return }
            handle.write(data)
            handle.write(Data([0x0A])) // newline
        }
    }

    private func openHandleIfNeeded() -> FileHandle? {
        if let fileHandle { return fileHandle }
        do {
            let directory = self.fileURL.deletingLastPathComponent()
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if !self.fileManager.fileExists(atPath: self.fileURL.path) {
                _ = self.fileManager.createFile(atPath: self.fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: self.fileURL)
            handle.seekToEndOfFile()
            self.fileHandle = handle
            return handle
        } catch {
            return nil
        }
    }
}
