import Foundation
import Logging

final class FileLogSink: @unchecked Sendable {
    static let shared = FileLogSink()
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("CodexBar.log")
    }()

    private let queue = DispatchQueue(label: "com.steipete.codexbar.filelog", qos: .utility)
    private let fileManager: FileManager
    private var isEnabled = false
    private var fileHandle: FileHandle?
    private var fileURL: URL = FileLogSink.defaultURL
    private let maxBytes: Int64 = 10 * 1024 * 1024

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func setEnabled(_ enabled: Bool, fileURL: URL = FileLogSink.defaultURL) {
        self.queue.async {
            self.isEnabled = enabled
            self.fileURL = fileURL
            if !enabled {
                self.closeHandle()
                return
            }
            _ = self.openHandleIfNeeded()
        }
    }

    func currentURL() -> URL {
        self.queue.sync { self.fileURL }
    }

    func write(_ text: String) {
        self.queue.async {
            guard self.isEnabled else { return }
            guard let data = text.data(using: .utf8) else { return }
            guard let handle = self.openHandleIfNeeded() else { return }
            handle.write(data)
        }
    }

    private func openHandleIfNeeded() -> FileHandle? {
        if let handle = self.fileHandle { return handle }
        do {
            try self.prepareFile(at: self.fileURL)
            let handle = try FileHandle(forWritingTo: self.fileURL)
            handle.seekToEndOfFile()
            self.fileHandle = handle
            return handle
        } catch {
            return nil
        }
    }

    private func prepareFile(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if self.fileManager.fileExists(atPath: url.path) {
            let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if size > self.maxBytes {
                try self.fileManager.removeItem(at: url)
            }
        }
        if !self.fileManager.fileExists(atPath: url.path) {
            _ = self.fileManager.createFile(atPath: url.path, contents: nil)
        }
    }

    private func closeHandle() {
        if let handle = self.fileHandle {
            try? handle.close()
        }
        self.fileHandle = nil
    }
}

struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let sink: FileLogSink

    init(label: String, sink: FileLogSink = .shared) {
        self.label = label
        self.sink = sink
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { self.metadata[metadataKey] }
        set { self.metadata[metadataKey] = newValue }
    }

    // swiftlint:disable:next function_parameter_count
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt)
    {
        let ts = Self.timestamp()
        var combined = self.metadata
        if let metadata { combined.merge(metadata, uniquingKeysWith: { _, new in new }) }
        var metaText = ""
        if !combined.isEmpty {
            let pairs = combined
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            metaText = " \(pairs)"
        }
        let lineText = "[\(ts)] [\(level.rawValue.uppercased())] \(self.label): \(message)\(metaText)\n"
        _ = source
        _ = file
        _ = function
        _ = line
        self.sink.write(lineText)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
