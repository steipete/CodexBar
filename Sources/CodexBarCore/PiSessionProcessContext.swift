import Foundation

/// The process command and working directory needed to resolve a live Pi-family session store.
public struct PiSessionProcessContext: Equatable, Sendable {
    public let command: String
    /// Original argv when available; this preserves whitespace inside flag values.
    public let arguments: [String]?
    /// The process CWD, when it could be read. An absolute `--session-dir` remains resolvable when this is nil.
    public let workingDirectory: URL?

    public init(command: String, arguments: [String]? = nil, workingDirectory: URL?) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory?.standardizedFileURL
    }
}
