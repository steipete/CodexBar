import Logging

struct CompositeLogHandler: LogHandler {
    private var primary: any LogHandler
    private var secondary: any LogHandler

    init(primary: any LogHandler, secondary: any LogHandler) {
        self.primary = primary
        self.secondary = secondary
    }

    var metadata: Logger.Metadata {
        get { self.primary.metadata }
        set {
            self.primary.metadata = newValue
            self.secondary.metadata = newValue
        }
    }

    var logLevel: Logger.Level {
        get { self.primary.logLevel }
        set {
            self.primary.logLevel = newValue
            self.secondary.logLevel = newValue
        }
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { self.primary[metadataKey: metadataKey] }
        set {
            self.primary[metadataKey: metadataKey] = newValue
            self.secondary[metadataKey: metadataKey] = newValue
        }
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
        self.primary.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line)
        self.secondary.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line)
    }
}
