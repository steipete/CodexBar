import Foundation

/// One explicitly selected SSH destination. Validation does not contact the destination.
public struct CodexRemoteLogSource: Codable, Equatable, Sendable {
    public var host: String
    public var home: String

    public init(host: String, home: String = "~/.codex") {
        self.host = host
        self.home = home
    }

    public func validate() throws {
        let parts = self.host.split(separator: "@", omittingEmptySubsequences: false)
        guard !self.host.isEmpty, self.host.utf8.count <= 255, parts.count <= 2,
              parts.allSatisfy({ part in
                  part.utf8.first.map { Self.isNameByte($0) && $0 != 45 } == true && part.utf8.allSatisfy {
                      Self.isNameByte($0) || $0 == 46
                  }
              }), Self.validHome(self.home)
        else { throw CodexRemoteLogError.invalidSource }
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || byte == 45 || byte == 95
    }

    static func validHome(_ home: String) -> Bool {
        guard home.utf8.count <= 1024, home.hasPrefix("/") || home.hasPrefix("~/") else { return false }
        let suffix = home.dropFirst(home.hasPrefix("~/") ? 2 : 1)
        return !suffix.isEmpty && suffix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy { Self.isNameByte($0) || $0 == 46 }
        }
    }
}

public struct CodexRemoteLogSnapshot: Sendable {
    public let roots: [URL]
    public let workDirectory: URL
    public let scanCacheRoot: URL
    public let capturedFrom: Date
    public let capturedTo: Date
}

/// Fixed messages only: subprocess output and remote paths never become public errors.
public enum CodexRemoteLogError: Error, LocalizedError, Sendable, Equatable {
    case invalidSource
    case missingDependency
    case remoteUnavailable
    case invalidManifest
    case inaccessibleRoot
    case unsafePath
    case budgetExceeded
    case unstableSource
    case transferFailed
    case timedOut
    case cancelled
    case localStorage
    case cleanupFailed

    public var isCleanupFailure: Bool {
        self == .cleanupFailed
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSource: "Enter a valid SSH destination and an absolute or ~/ remote home."
        case .missingDependency: "SSH log collection requires SSH, rsync and Linux find, stat and sha256sum."
        case .remoteUnavailable: "The SSH log source could not be read. Check connectivity and noninteractive access."
        case .invalidManifest: "The server log manifest was incomplete or invalid."
        case .inaccessibleRoot: "A server log directory exists but cannot be read."
        case .unsafePath: "The log transfer contains an unsupported path, file type, or received file permissions."
        case .budgetExceeded: "The server logs exceed the collection resource limit."
        case .unstableSource: "Server logs changed during collection. Retry when the logs are stable."
        case .transferFailed: "The server log transfer did not complete."
        case .timedOut: "Server log collection exceeded its time limit."
        case .cancelled: "Server log collection was cancelled."
        case .localStorage: "Private temporary storage for server logs could not be created or verified."
        case .cleanupFailed: "Temporary server logs could not be removed. Retry cleanup before refreshing."
        }
    }
}
