import Foundation

/// Bounded, in-memory, on-demand indexing. Nothing is persisted or included in billing refreshes.
public actor SessionToolActivityStore {
    public static let shared = SessionToolActivityStore()
    private var cache: [SessionToolActivitySource: SessionToolActivitySnapshot] = [:]
    private var recentSources: [SessionToolActivitySource] = []
    static let maximumScanBytes: UInt64 = 256 * 1024 * 1024
    static let maximumOperations = 20000
    static let maximumCachedOperations = 20000

    var cachedOperationCount: Int {
        self.cache.values.reduce(0) { $0 + $1.operations.count }
    }

    public init() {}

    public func load(source: SessionToolActivitySource) throws -> SessionToolActivitySnapshot {
        try Task.checkCancellation()
        let stamp = try Self.stamp(source.fileURL)
        if let cached = self.cache[source], Self.matches(cached, stamp) { return cached }
        let snapshot = try Self.scan(source: source, stamp: stamp)
        try Task.checkCancellation()
        guard try Self.matches(snapshot, Self.stamp(source.fileURL)) else {
            throw SessionToolActivityError.sourceChanged
        }
        self.cache[source] = snapshot
        self.recentSources.removeAll { $0 == source }
        self.recentSources.append(source)
        while self.recentSources.count > 4 || self.cachedOperationCount > Self.maximumCachedOperations {
            self.cache.removeValue(forKey: self.recentSources.removeFirst())
        }
        return snapshot
    }

    public func details(
        operation: SessionToolOperation,
        snapshot: SessionToolActivitySnapshot) throws -> SessionToolOperationDetails
    {
        try Task.checkCancellation()
        guard snapshot.operations.contains(operation), try Self.matches(snapshot, Self.stamp(snapshot.source.fileURL))
        else { throw SessionToolActivityError.sourceChanged }
        let handle = try FileHandle(forReadingFrom: snapshot.source.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: operation.recordOffset)
        // Oversized records remain inspectable as a labeled preview; never allocate an unbounded result.
        let limit = 4 * 1024 * 1024
        guard operation.recordLength > 0, operation.recordOffset <= snapshot.fileSize,
              UInt64(operation.recordLength) <= snapshot.fileSize - operation.recordOffset
        else {
            throw SessionToolActivityError.sourceChanged
        }
        let bytes = try handle.read(upToCount: min(operation.recordLength, limit)) ?? Data()
        try Task.checkCancellation()
        guard bytes.count == min(operation.recordLength, limit),
              try Self.matches(snapshot, Self.stamp(snapshot.source.fileURL))
        else {
            throw SessionToolActivityError.sourceChanged
        }
        if operation.recordLength > limit {
            return SessionToolOperationDetails(
                input: operation.preview,
                // A byte-limited preview can end inside a UTF-8 scalar; preserve the readable prefix.
                // swiftlint:disable:next optional_data_string_conversion
                output: String(decoding: Array(bytes.prefix(32768)), as: UTF8.self),
                isTruncated: true,
                outputIsRawRecord: true)
        }
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let payload = root["payload"] as? [String: Any], let item = payload["item"] as? [String: Any],
              let recorded = SessionToolActivityParser.operation(
                  from: root,
                  source: snapshot.source,
                  offset: operation.recordOffset,
                  length: operation.recordLength),
              recorded.id == operation.id, recorded.kind == operation.kind
        else { throw SessionToolActivityError.unavailable }
        let inputText = ["command", "arguments", "changes"].lazy.compactMap { Self.text(item[$0]) }.first
        let outputText = ["aggregated_output", "result", "content_items", "error", "formatted_output"].lazy
            .compactMap { Self.text(item[$0]) }.first
            ?? ["stdout", "stderr"].compactMap { Self.text(item[$0]) }.joined(separator: "\n")
        let input = inputText.map { SessionToolTextPreview.prefix($0, characters: 16000, bytes: 64000) }
        let output = SessionToolTextPreview.prefix(outputText, characters: 32000, bytes: 128_000)
        try Task.checkCancellation()
        return SessionToolOperationDetails(
            input: input,
            output: output.isEmpty ? nil : output,
            isTruncated: input != inputText || output != outputText)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let command = value as? [String] { return command.joined(separator: " ") }
        guard JSONSerialization.isValidJSONObject(value),
              var bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        // Pretty-print small structures only; indentation can greatly amplify a deeply nested result.
        if bytes.count <= 64000,
           let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        {
            bytes = formatted
        }
        return String(data: bytes, encoding: .utf8)
    }

    private struct Stamp {
        let size: UInt64
        let modified: Date
        let number: UInt64
    }

    private static func stamp(_ url: URL) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber
        else {
            throw SessionToolActivityError.unavailable
        }
        return Stamp(size: size.uint64Value, modified: date, number: number.uint64Value)
    }

    private static func matches(_ snapshot: SessionToolActivitySnapshot, _ stamp: Stamp) -> Bool {
        snapshot.fileSize == stamp.size && snapshot.modificationDate == stamp.modified && snapshot.fileNumber == stamp
            .number
    }

    private static func scan(source: SessionToolActivitySource, stamp: Stamp) throws -> SessionToolActivitySnapshot {
        let handle = try FileHandle(forReadingFrom: source.fileURL)
        defer { try? handle.close() }
        var projector = SessionToolJSONProjection()
        var operations: [SessionToolOperation] = []
        var operationIndices: [SessionToolOperation.Identity: Int] = [:]
        var offset: UInt64 = 0
        var start: UInt64 = 0
        var ignored = 0
        let limit = min(stamp.size, Self.maximumScanBytes)
        while offset < limit, operations.count < Self.maximumOperations {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: Int(min(65536, limit - offset))) ?? Data()
            if data.isEmpty { break }
            for byte in data {
                offset += 1
                if byte == 10 {
                    if let projected = projector.finish(),
                       let root = try? JSONSerialization.jsonObject(with: projected) as? [String: Any]
                    {
                        if let operation = SessionToolActivityParser.operation(
                            from: root, source: source, offset: start, length: Int(offset - start))
                        {
                            if let index = operationIndices[operation.id] {
                                operations[index] = operation
                            } else {
                                operationIndices[operation.id] = operations.count
                                operations.append(operation)
                            }
                        } else if SessionToolActivityParser.isUnindexedNativeOperation(root, source: source) {
                            ignored += 1
                        }
                    } else if projector.hasBytes {
                        ignored += 1
                    }
                    projector = SessionToolJSONProjection()
                    start = offset
                    if operations.count >= Self.maximumOperations { break }
                } else {
                    projector.consume(byte)
                }
            }
        }
        // Uncommitted trailing records are deliberately excluded and reported as partial coverage.
        return SessionToolActivitySnapshot(
            source: source,
            operations: operations.sorted {
                $0.completedAt == $1.completedAt ? $0.recordOffset > $1.recordOffset : $0.completedAt > $1.completedAt
            },
            ignoredRecordCount: ignored,
            isPartial: offset < stamp.size || projector.hasBytes || ignored > 0,
            fileSize: stamp.size,
            modificationDate: stamp.modified,
            fileNumber: stamp.number)
    }
}
