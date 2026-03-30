import Foundation

public struct CodexSessionSummary: Sendable, Equatable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let durationSeconds: TimeInterval
    public let toolCallCount: Int
    public let toolFailureCount: Int
    public let longRunningCallCount: Int
    public let verificationAttemptCount: Int
    public let toolCountsByName: [String: Int]

    public init(
        id: String,
        title: String,
        startedAt: Date,
        durationSeconds: TimeInterval,
        toolCallCount: Int,
        toolFailureCount: Int,
        longRunningCallCount: Int,
        verificationAttemptCount: Int,
        toolCountsByName: [String: Int])
    {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.toolCallCount = toolCallCount
        self.toolFailureCount = toolFailureCount
        self.longRunningCallCount = longRunningCallCount
        self.verificationAttemptCount = verificationAttemptCount
        self.toolCountsByName = toolCountsByName
    }
}

public struct CodexToolAggregate: Sendable, Equatable {
    public let name: String
    public let callCount: Int

    public init(name: String, callCount: Int) {
        self.name = name
        self.callCount = callCount
    }
}

public struct CodexSessionAnalyticsSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let sessions: [CodexSessionSummary]
    public let medianSessionDurationSeconds: TimeInterval
    public let medianToolCallsPerSession: Double
    public let toolFailureRate: Double
    public let topTools: [CodexToolAggregate]

    public init(
        generatedAt: Date,
        sessions: [CodexSessionSummary],
        medianSessionDurationSeconds: TimeInterval,
        medianToolCallsPerSession: Double,
        toolFailureRate: Double,
        topTools: [CodexToolAggregate])
    {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.medianSessionDurationSeconds = medianSessionDurationSeconds
        self.medianToolCallsPerSession = medianToolCallsPerSession
        self.toolFailureRate = toolFailureRate
        self.topTools = topTools
    }

    public var sessionsAnalyzed: Int {
        self.sessions.count
    }

    public var recentSessions: [CodexSessionSummary] {
        Array(self.sessions.prefix(8))
    }
}

public struct CodexSessionAnalyticsLoader {
    private let env: [String: String]
    private let fileManager: FileManager
    private let homeDirectoryURL: URL?
    private let iso8601Formatter: ISO8601DateFormatter

    private static let verificationPattern = try? NSRegularExpression(
        pattern: verificationPatternString)
    private static let nonZeroExitPattern = try? NSRegularExpression(
        pattern: #"Process exited with code\s+(-?\d+)"#)
    private static let wallTimePattern = try? NSRegularExpression(
        pattern: #"Wall time:\s*([0-9]*\.?[0-9]+)\s*(ms|milliseconds?|s|sec|secs|second|seconds)"#,
        options: [.caseInsensitive])

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil)
    {
        self.env = env
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = formatter
    }

    private static let verificationPatternString =
        #"(?i)(?:\bxcodebuild\s+test\b|\bswift\s+test\b|\bcargo\s+test\b|\bnpm\s+test\b|"# +
        #"\bpnpm\s+test\b|\bbun\s+test\b|\bpytest\b|\bvitest\b|\bplaywright\b|"# +
        #"\blint\b|\bbuild\b|\btest\b)"#

    public func loadSnapshot(maxSessions: Int = 20, now: Date = .now) throws -> CodexSessionAnalyticsSnapshot? {
        let candidates = self.rolloutCandidates()
        guard !candidates.isEmpty else { return nil }

        var sessions: [CodexSessionSummary] = []
        sessions.reserveCapacity(min(maxSessions, candidates.count))

        for fileURL in candidates {
            if let summary = self.parseSessionFile(fileURL) {
                sessions.append(summary)
            }
        }

        let sortedSessions = sessions
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt > $1.startedAt
                }
                return $0.id > $1.id
            }
        let recentSessions = Array(sortedSessions.prefix(maxSessions))
        guard !recentSessions.isEmpty else { return nil }

        let totalToolCalls = recentSessions.reduce(0) { $0 + $1.toolCallCount }
        let totalFailures = recentSessions.reduce(0) { $0 + $1.toolFailureCount }

        var toolTotals: [String: Int] = [:]
        for session in recentSessions {
            for (name, count) in session.toolCountsByName {
                toolTotals[name, default: 0] += count
            }
        }

        let topTools = toolTotals
            .map { CodexToolAggregate(name: $0.key, callCount: $0.value) }
            .sorted {
                if $0.callCount != $1.callCount {
                    return $0.callCount > $1.callCount
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(5)

        let medianDuration = Self.median(recentSessions.map(\.durationSeconds))
        let medianToolCalls = Self.median(recentSessions.map { Double($0.toolCallCount) })
        let failureRate = totalToolCalls > 0 ? Double(totalFailures) / Double(totalToolCalls) : 0

        return CodexSessionAnalyticsSnapshot(
            generatedAt: now,
            sessions: recentSessions,
            medianSessionDurationSeconds: medianDuration,
            medianToolCallsPerSession: medianToolCalls,
            toolFailureRate: failureRate,
            topTools: Array(topTools))
    }

    private func rolloutCandidates() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let roots = [self.sessionsRoot(), self.archivedSessionsRoot()]

        var urls: [URL] = []
        urls.reserveCapacity(64)

        for root in roots {
            guard self.fileManager.fileExists(atPath: root.path),
                  let enumerator = self.fileManager.enumerator(
                      at: root,
                      includingPropertiesForKeys: keys,
                      options: options)
            else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension.lowercased() == "jsonl"
                else { continue }

                let isRegular = (try? fileURL.resourceValues(forKeys: Set(keys)).isRegularFile) ?? true
                if isRegular == false { continue }
                urls.append(fileURL)
            }
        }

        return urls.sorted(by: self.isPreferredCandidate(_:_:))
    }

    private func isPreferredCandidate(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        switch (leftDate, rightDate) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.path > rhs.path
        }
    }

    private func sessionsRoot() -> URL {
        self.codexHomeRoot().appendingPathComponent("sessions", isDirectory: true)
    }

    private func archivedSessionsRoot() -> URL {
        self.codexHomeRoot().appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private func codexHomeRoot() -> URL {
        if let raw = self.env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return (self.homeDirectoryURL ?? self.fileManager.homeDirectoryForCurrentUser)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func parseSessionFile(_ fileURL: URL) -> CodexSessionSummary? {
        var state = SessionAccumulator()

        do {
            try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024)
            { line in
                guard !line.wasTruncated,
                      let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any],
                      let type = object["type"] as? String
                else { return }

                if let eventAt = self.parseDate(object["timestamp"] as? String) {
                    state.recordEvent(at: eventAt)
                }

                self.apply(object: object, type: type, to: &state)
            }
        } catch {
            return nil
        }

        return state.summary(fileURL: fileURL)
    }

    private func apply(object: [String: Any], type: String, to state: inout SessionAccumulator) {
        switch type {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any] else { return }
            if state.id == nil {
                state.id = payload["id"] as? String
            }
            if state.startedAt == nil {
                state.startedAt = self.parseDate(payload["timestamp"] as? String)
            }

        case "event_msg":
            guard state.title == nil,
                  let payload = object["payload"] as? [String: Any],
                  (payload["type"] as? String) == "user_message",
                  let message = payload["message"] as? String
            else { return }
            state.title = Self.makeTitle(from: message)

        case "response_item":
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { return }
            Self.applyResponseItem(payload, type: payloadType, to: &state)

        default:
            return
        }
    }

    private static func applyResponseItem(
        _ payload: [String: Any],
        type: String,
        to state: inout SessionAccumulator)
    {
        switch type {
        case "function_call":
            state.toolCallCount += 1
            if let name = payload["name"] as? String, !name.isEmpty {
                state.toolCountsByName[name, default: 0] += 1
            }
            if let commandText = commandText(from: payload), isVerificationAttempt(commandText) {
                state.verificationAttemptCount += 1
            }

        case "function_call_output":
            guard let output = payload["output"] as? String else { return }
            if self.isFailureOutput(output) {
                state.toolFailureCount += 1
            }
            if self.wallTimeSeconds(in: output) > 5 {
                state.longRunningCallCount += 1
            }

        default:
            return
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let parsed = self.iso8601Formatter.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private static func makeTitle(from message: String) -> String {
        let firstLine = message
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let title = firstLine ?? "Untitled session"
        if title.count <= 88 {
            return title
        }
        let end = title.index(title.startIndex, offsetBy: 85)
        return String(title[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func fallbackTitle(for fileURL: URL) -> String {
        let base = fileURL.deletingPathExtension().lastPathComponent
        if base.hasPrefix("rollout-") {
            return String(base.dropFirst("rollout-".count))
        }
        return base
    }

    private static func commandText(from payload: [String: Any]) -> String? {
        guard let arguments = payload["arguments"] as? String, !arguments.isEmpty else { return nil }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return arguments
        }

        for key in ["cmd", "chars", "text", "value"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return arguments
    }

    private static func isVerificationAttempt(_ commandText: String) -> Bool {
        guard let regex = verificationPattern else { return false }
        let range = NSRange(commandText.startIndex..<commandText.endIndex, in: commandText)
        return regex.firstMatch(in: commandText, range: range) != nil
    }

    private static func isFailureOutput(_ output: String) -> Bool {
        if output.localizedCaseInsensitiveContains("tool call error:") {
            return true
        }

        guard let regex = nonZeroExitPattern else { return false }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let codeRange = Range(match.range(at: 1), in: output),
              let code = Int(output[codeRange])
        else {
            return false
        }
        return code != 0
    }

    private static func wallTimeSeconds(in output: String) -> TimeInterval {
        guard let regex = wallTimePattern else { return 0 }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let value = Double(output[valueRange])
        else {
            return 0
        }

        let unit = output[unitRange].lowercased()
        if unit.hasPrefix("ms") || unit.hasPrefix("millisecond") {
            return value / 1000
        }
        return value
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

private struct SessionAccumulator {
    var id: String?
    var title: String?
    var startedAt: Date?
    var firstEventAt: Date?
    var lastEventAt: Date?
    var toolCallCount = 0
    var toolFailureCount = 0
    var longRunningCallCount = 0
    var verificationAttemptCount = 0
    var toolCountsByName: [String: Int] = [:]

    mutating func recordEvent(at eventAt: Date) {
        if self.firstEventAt == nil || eventAt < self.firstEventAt! {
            self.firstEventAt = eventAt
        }
        if self.lastEventAt == nil || eventAt > self.lastEventAt! {
            self.lastEventAt = eventAt
        }
    }

    func summary(fileURL: URL) -> CodexSessionSummary? {
        let resolvedID = self.id ?? fileURL.deletingPathExtension().lastPathComponent
        let resolvedStartedAt = self.startedAt ?? self.firstEventAt
        guard let resolvedStartedAt else { return nil }

        let start = self.firstEventAt ?? resolvedStartedAt
        let end = self.lastEventAt ?? resolvedStartedAt
        let durationSeconds = max(0, end.timeIntervalSince(start))

        return CodexSessionSummary(
            id: resolvedID,
            title: self.title ?? CodexSessionAnalyticsLoader.fallbackTitle(for: fileURL),
            startedAt: resolvedStartedAt,
            durationSeconds: durationSeconds,
            toolCallCount: self.toolCallCount,
            toolFailureCount: self.toolFailureCount,
            longRunningCallCount: self.longRunningCallCount,
            verificationAttemptCount: self.verificationAttemptCount,
            toolCountsByName: self.toolCountsByName)
    }
}
