import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct JSONStderrLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let encoder: JSONEncoder

    init(label: String) {
        self.label = label
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { self.metadata[metadataKey] }
        set { self.metadata[metadataKey] = newValue }
    }

    func log(event: LogEvent) {
        let ts = Date()
        var combined = self.metadata
        if let metadata = event.metadata { combined.merge(metadata, uniquingKeysWith: { _, new in new }) }

        let payload = JSONLogLine(
            timestamp: ts,
            level: event.level.rawValue,
            label: self.label,
            message: event.message.description,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line,
            metadata: combined.isEmpty ? nil : combined.mapValues(\.description))

        guard let data = try? self.encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        Self.writeStderr(text + "\n")
    }
}

private struct JSONLogLine: Encodable {
    let timestamp: Date
    let level: String
    let label: String
    let message: String
    let source: String
    let file: String
    let function: String
    let line: UInt
    let metadata: [String: String]?
}

extension JSONStderrLogHandler {
    private static func writeStderr(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = write(STDERR_FILENO, baseAddress, buffer.count)
        }
    }
}
