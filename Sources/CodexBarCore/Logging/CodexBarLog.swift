import Foundation
import Logging

public enum CodexBarLog {
    public enum Destination: Sendable {
        case stderr
        case oslog(subsystem: String)
    }

    public enum Level: String, CaseIterable, Identifiable, Sendable {
        case trace
        case verbose
        case debug
        case info
        case warning
        case error
        case critical

        public var id: String {
            self.rawValue
        }

        public var displayName: String {
            switch self {
            case .trace: "Trace"
            case .verbose: "Verbose"
            case .debug: "Debug"
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            case .critical: "Critical"
            }
        }

        public var rank: Int {
            switch self {
            case .trace: 0
            case .verbose: 1
            case .debug: 2
            case .info: 3
            case .warning: 4
            case .error: 5
            case .critical: 6
            }
        }

        public var asSwiftLogLevel: Logger.Level {
            switch self {
            case .trace: .trace
            case .verbose: .debug
            case .debug: .debug
            case .info: .info
            case .warning: .warning
            case .error: .error
            case .critical: .critical
            }
        }
    }

    public struct Configuration: Sendable {
        public let destination: Destination
        public let level: Level
        public let json: Bool

        public init(destination: Destination, level: Level, json: Bool) {
            self.destination = destination
            self.level = level
            self.json = json
        }
    }

    private static let lock = NSLock()
    private static let levelLock = NSLock()
    private nonisolated(unsafe) static var isBootstrapped = false
    private nonisolated(unsafe) static var currentLevel: Level = .info

    public static func bootstrapIfNeeded(_ config: Configuration) {
        self.lock.lock()
        defer { lock.unlock() }
        guard !self.isBootstrapped else { return }
        self.currentLevel = config.level

        let baseFactory: @Sendable (String) -> any LogHandler = { label in
            switch config.destination {
            case .stderr:
                if config.json { return JSONStderrLogHandler(label: label) }
                return StreamLogHandler.standardError(label: label)
            case let .oslog(subsystem):
                #if canImport(os)
                return OSLogLogHandler(label: label, subsystem: subsystem)
                #else
                if config.json { return JSONStderrLogHandler(label: label) }
                return StreamLogHandler.standardError(label: label)
                #endif
            }
        }

        LoggingSystem.bootstrap { label in
            let primary = baseFactory(label)
            let fileHandler = FileLogHandler(label: label)
            var handler = CompositeLogHandler(primary: primary, secondary: fileHandler)
            handler.logLevel = .trace
            return handler
        }

        self.isBootstrapped = true
    }

    public static func logger(_ category: String) -> CodexBarLogger {
        let logger = Logger(label: "com.steipete.codexbar.\(category)")
        return CodexBarLogger { level, message, metadata in
            guard self.shouldLog(level) else { return }
            let swiftLogLevel = level.asSwiftLogLevel
            let safeMessage = LogRedactor.redact(message)
            let meta = metadata?.reduce(into: Logger.Metadata()) { partial, entry in
                partial[entry.key] = .string(LogRedactor.redact(entry.value))
            }
            logger.log(level: swiftLogLevel, "\(safeMessage)", metadata: meta)
        }
    }

    public static func parseLevel(_ raw: String?) -> Level? {
        guard let raw, !raw.isEmpty else { return nil }
        return Level(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func setLogLevel(_ level: Level) {
        self.levelLock.lock()
        self.currentLevel = level
        self.levelLock.unlock()
        let logger = self.logger(LogCategories.logging)
        logger.info("Log level set to \(level.rawValue)")
    }

    public static func currentLogLevel() -> Level {
        self.levelLock.lock()
        defer { self.levelLock.unlock() }
        return self.currentLevel
    }

    private static func shouldLog(_ level: Level) -> Bool {
        level.rank >= self.currentLogLevel().rank
    }

    public static var fileLogURL: URL {
        FileLogSink.defaultURL
    }

    public static func setFileLoggingEnabled(_ enabled: Bool) {
        FileLogSink.shared.setEnabled(enabled, fileURL: self.fileLogURL)
        let state = enabled ? "enabled" : "disabled"
        let logger = self.logger(LogCategories.logging)
        logger.info("File logging \(state)", metadata: ["path": self.fileLogURL.path])
    }
}

public struct CodexBarLogger: Sendable {
    private let logFn: @Sendable (CodexBarLog.Level, String, [String: String]?) -> Void

    fileprivate init(_ logFn: @escaping @Sendable (CodexBarLog.Level, String, [String: String]?) -> Void) {
        self.logFn = logFn
    }

    public func trace(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.trace, message(), metadata)
    }

    public func verbose(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.verbose, message(), metadata)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.debug, message(), metadata)
    }

    public func info(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.info, message(), metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.warning, message(), metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.error, message(), metadata)
    }

    public func critical(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.logFn(.critical, message(), metadata)
    }
}
