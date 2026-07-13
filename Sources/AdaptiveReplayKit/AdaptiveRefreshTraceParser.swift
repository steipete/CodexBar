import Foundation

/// A malformed trace line, with enough context to find and fix it.
public struct AdaptiveRefreshTraceParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let lineNumber: Int
    public let content: String
    public let underlyingDescription: String

    public init(lineNumber: Int, content: String, underlyingDescription: String) {
        self.lineNumber = lineNumber
        self.content = content
        self.underlyingDescription = underlyingDescription
    }

    public var description: String {
        "trace line \(self.lineNumber) is malformed: \(self.underlyingDescription) (content: \(self.content))"
    }
}

/// Parses newline-delimited JSON adaptive-refresh traces.
///
/// Deliberate choice: a malformed line **fails the whole parse** rather than being silently
/// skipped. A trace is acceptance evidence — if a line is corrupt (truncated write, disk-full
/// mid-append, hand-edited fixture with a typo), the honest answer is "this trace is untrustworthy
/// as a whole", not "here are metrics computed from however much of it happened to parse". A
/// silently-shortened trace would still produce a superficially plausible replay report, which is
/// worse than a loud failure: it hides exactly the kind of gap that would bias staleness/refresh
/// counts. Callers that genuinely want best-effort parsing can catch the error and fall back to
/// `AdaptiveRefreshTraceParser.parseTolerantly`, which skips bad lines and returns what parsed.
public enum AdaptiveRefreshTraceParser {
    public static func parse(_ text: String) throws -> [AdaptiveRefreshTraceRecord] {
        let decoder = Self.makeDecoder()
        var records: [AdaptiveRefreshTraceRecord] = []
        for (index, line) in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline).enumerated()
        {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw AdaptiveRefreshTraceParseError(
                    lineNumber: index + 1,
                    content: trimmed,
                    underlyingDescription: "not valid UTF-8")
            }
            do {
                try records.append(decoder.decode(AdaptiveRefreshTraceRecord.self, from: data))
            } catch {
                throw AdaptiveRefreshTraceParseError(
                    lineNumber: index + 1,
                    content: trimmed,
                    underlyingDescription: String(describing: error))
            }
        }
        return records
    }

    public static func parse(contentsOf url: URL) throws -> [AdaptiveRefreshTraceRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try self.parse(text)
    }

    /// Best-effort variant: skips lines that fail to parse instead of throwing. Not the default —
    /// see the type-level documentation for why silent skipping is the wrong default for
    /// acceptance-evidence traces. Exists for callers (future exploratory tooling) that explicitly
    /// want partial data over none.
    public static func parseTolerantly(_ text: String) -> [AdaptiveRefreshTraceRecord] {
        let decoder = Self.makeDecoder()
        var records: [AdaptiveRefreshTraceRecord] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let record = try? decoder.decode(AdaptiveRefreshTraceRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
