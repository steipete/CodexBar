import Foundation

/// A source supplied by the native usage scanner, never rediscovered from the UI's home directory.
public struct SessionToolActivitySource: Sendable, Equatable, Hashable {
    public let fileURL: URL
    public let sessionID: String

    public init(fileURL: URL, sessionID: String) {
        self.fileURL = fileURL
        self.sessionID = sessionID
    }
}

public struct SessionToolOperation: Sendable, Equatable, Identifiable {
    public struct Identity: Sendable, Equatable, Hashable {
        public let threadID: String
        public let turnID: String
        public let itemID: String
    }

    public enum Kind: String, Sendable {
        case command, mcp, dynamic, fileChange, webSearch, image, extensionItem
    }

    public enum Outcome: String, Sendable {
        case completed, nonzeroExit, toolError, declined, unknown
    }

    public enum Timing: String, Sendable {
        case native, recordedInterval
    }

    public let id: Identity
    public let kind: Kind
    /// Fully qualified server/tool name for MCP, or native operation category.
    public let name: String
    public let preview: String?
    public let completedAt: Date
    public let outcome: Outcome
    public let exitCode: Int?
    public let durationMilliseconds: Double?
    public let timing: Timing?
    public let recordOffset: UInt64
    public let recordLength: Int

    public var needsAttention: Bool {
        self.outcome == .nonzeroExit || self.outcome == .toolError || self.outcome == .declined
    }

    /// An explicit display threshold, not a percentile or a task failure classification.
    public var isSlow: Bool {
        (self.durationMilliseconds ?? -1) >= 10000
    }
}

public struct SessionToolActivitySnapshot: Sendable, Equatable {
    public let source: SessionToolActivitySource
    public let operations: [SessionToolOperation]
    public let ignoredRecordCount: Int
    public let isPartial: Bool
    public let fileSize: UInt64
    public let modificationDate: Date
    /// Distinguishes a replaced file even when its size and modification date are preserved.
    public let fileNumber: UInt64

    public func operations(in range: Range<Date>?) -> [SessionToolOperation] {
        guard let range else { return self.operations }
        return self.operations.filter { range.contains($0.completedAt) }
    }
}

public struct SessionToolOperationDetails: Sendable, Equatable {
    public let input: String?
    public let output: String?
    public let isTruncated: Bool
    public var outputIsRawRecord: Bool = false
}

public enum SessionToolActivityError: Error, Sendable {
    case sourceChanged
    case unavailable
}
