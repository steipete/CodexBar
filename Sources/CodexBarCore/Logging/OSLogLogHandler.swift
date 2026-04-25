#if canImport(os)
import Foundation
import Logging
import os

struct OSLogLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    private let label: String
    private let subsystem: String
    private let logger: os.Logger

    init(label: String, subsystem: String) {
        self.label = label
        self.subsystem = subsystem
        let category = Self.category(from: label, subsystem: subsystem)
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get { self.metadata[metadataKey] }
        set { self.metadata[metadataKey] = newValue }
    }

    func log(event: LogEvent) {
        let msg = Self.decorate(
            message: event.message.description,
            label: self.label,
            subsystem: self.subsystem,
            metadata: self.metadata,
            extraMetadata: event.metadata)

        switch event.level {
        case .trace:
            self.logger.debug("\(msg, privacy: .public)")
        case .debug:
            self.logger.debug("\(msg, privacy: .public)")
        case .info, .notice:
            self.logger.info("\(msg, privacy: .public)")
        case .warning:
            self.logger.warning("\(msg, privacy: .public)")
        case .error:
            self.logger.error("\(msg, privacy: .public)")
        case .critical:
            self.logger.fault("\(msg, privacy: .public)")
        }
    }

    private static func category(from label: String, subsystem: String) -> String {
        let prefix = subsystem + "."
        guard label.hasPrefix(prefix) else { return label }
        return String(label.dropFirst(prefix.count))
    }

    private static func decorate(
        message: String,
        label: String,
        subsystem: String,
        metadata: Logging.Logger.Metadata,
        extraMetadata: Logging.Logger.Metadata?)
        -> String
    {
        var merged = metadata
        if let extraMetadata { merged.merge(extraMetadata, uniquingKeysWith: { _, new in new }) }
        guard !merged.isEmpty else { return message }

        let suffix = merged
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        _ = label
        _ = subsystem
        return "\(message) (\(suffix))"
    }
}
#endif
