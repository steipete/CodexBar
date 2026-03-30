import Foundation

public struct CodexSessionTokenUsage: Sendable, Equatable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(
        totalTokens: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int)
    {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

public struct CodexSessionAnalyticsSummaryDiagnostics: Sendable, Equatable {
    public let windowSpanSeconds: TimeInterval
    public let sessionsWithTokens: Int
    public let sessionsWithFailures: Int
    public let sessionsWithChecks: Int
    public let durationP25Seconds: TimeInterval
    public let durationP50Seconds: TimeInterval
    public let durationP75Seconds: TimeInterval
    public let longestSessionDurationSeconds: TimeInterval
    public let top3DurationShare: Double
    public let avgToolCalls: Double
    public let toolCallsP75: Double
    public let sessionsOver50Calls: Int
    public let sessionsOver100Calls: Int
    public let maxToolCallsInSingleSession: Int
    public let failedCalls: Int
    public let totalCalls: Int
    public let topFailingToolName: String?
    public let topFailingToolFailures: Int

    public static let empty = CodexSessionAnalyticsSummaryDiagnostics(
        windowSpanSeconds: 0,
        sessionsWithTokens: 0,
        sessionsWithFailures: 0,
        sessionsWithChecks: 0,
        durationP25Seconds: 0,
        durationP50Seconds: 0,
        durationP75Seconds: 0,
        longestSessionDurationSeconds: 0,
        top3DurationShare: 0,
        avgToolCalls: 0,
        toolCallsP75: 0,
        sessionsOver50Calls: 0,
        sessionsOver100Calls: 0,
        maxToolCallsInSingleSession: 0,
        failedCalls: 0,
        totalCalls: 0,
        topFailingToolName: nil,
        topFailingToolFailures: 0)

    public init(
        windowSpanSeconds: TimeInterval,
        sessionsWithTokens: Int,
        sessionsWithFailures: Int,
        sessionsWithChecks: Int,
        durationP25Seconds: TimeInterval,
        durationP50Seconds: TimeInterval,
        durationP75Seconds: TimeInterval,
        longestSessionDurationSeconds: TimeInterval,
        top3DurationShare: Double,
        avgToolCalls: Double,
        toolCallsP75: Double,
        sessionsOver50Calls: Int,
        sessionsOver100Calls: Int,
        maxToolCallsInSingleSession: Int,
        failedCalls: Int,
        totalCalls: Int,
        topFailingToolName: String?,
        topFailingToolFailures: Int)
    {
        self.windowSpanSeconds = windowSpanSeconds
        self.sessionsWithTokens = sessionsWithTokens
        self.sessionsWithFailures = sessionsWithFailures
        self.sessionsWithChecks = sessionsWithChecks
        self.durationP25Seconds = durationP25Seconds
        self.durationP50Seconds = durationP50Seconds
        self.durationP75Seconds = durationP75Seconds
        self.longestSessionDurationSeconds = longestSessionDurationSeconds
        self.top3DurationShare = top3DurationShare
        self.avgToolCalls = avgToolCalls
        self.toolCallsP75 = toolCallsP75
        self.sessionsOver50Calls = sessionsOver50Calls
        self.sessionsOver100Calls = sessionsOver100Calls
        self.maxToolCallsInSingleSession = maxToolCallsInSingleSession
        self.failedCalls = failedCalls
        self.totalCalls = totalCalls
        self.topFailingToolName = topFailingToolName
        self.topFailingToolFailures = topFailingToolFailures
    }
}

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
    public let toolFailureCountsByName: [String: Int]
    public let toolLongRunningCountsByName: [String: Int]
    public let tokenUsage: CodexSessionTokenUsage?

    public init(
        id: String,
        title: String,
        startedAt: Date,
        durationSeconds: TimeInterval,
        toolCallCount: Int,
        toolFailureCount: Int,
        longRunningCallCount: Int,
        verificationAttemptCount: Int,
        toolCountsByName: [String: Int],
        toolFailureCountsByName: [String: Int] = [:],
        toolLongRunningCountsByName: [String: Int] = [:],
        tokenUsage: CodexSessionTokenUsage? = nil)
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
        self.toolFailureCountsByName = toolFailureCountsByName
        self.toolLongRunningCountsByName = toolLongRunningCountsByName
        self.tokenUsage = tokenUsage
    }
}

public struct CodexToolAggregate: Sendable, Equatable {
    public let name: String
    public let callCount: Int
    public let sessionCountUsingTool: Int
    public let callShare: Double
    public let averageCallsPerActiveSession: Double
    public let maxCallsInSingleSession: Int
    public let maxCallsSessionTitle: String?
    public let failureCount: Int
    public let failureRate: Double
    public let sessionsWithToolFailure: Int
    public let longRunningCount: Int

    public init(
        name: String,
        callCount: Int,
        sessionCountUsingTool: Int = 0,
        callShare: Double = 0,
        averageCallsPerActiveSession: Double = 0,
        maxCallsInSingleSession: Int = 0,
        maxCallsSessionTitle: String? = nil,
        failureCount: Int = 0,
        failureRate: Double = 0,
        sessionsWithToolFailure: Int = 0,
        longRunningCount: Int = 0)
    {
        self.name = name
        self.callCount = callCount
        self.sessionCountUsingTool = sessionCountUsingTool
        self.callShare = callShare
        self.averageCallsPerActiveSession = averageCallsPerActiveSession
        self.maxCallsInSingleSession = maxCallsInSingleSession
        self.maxCallsSessionTitle = maxCallsSessionTitle
        self.failureCount = failureCount
        self.failureRate = failureRate
        self.sessionsWithToolFailure = sessionsWithToolFailure
        self.longRunningCount = longRunningCount
    }
}

public struct CodexSessionAnalyticsSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let sessions: [CodexSessionSummary]
    public let medianSessionDurationSeconds: TimeInterval
    public let medianToolCallsPerSession: Double
    public let toolFailureRate: Double
    public let topTools: [CodexToolAggregate]
    public let summaryDiagnostics: CodexSessionAnalyticsSummaryDiagnostics

    public init(
        generatedAt: Date,
        sessions: [CodexSessionSummary],
        medianSessionDurationSeconds: TimeInterval,
        medianToolCallsPerSession: Double,
        toolFailureRate: Double,
        topTools: [CodexToolAggregate],
        summaryDiagnostics: CodexSessionAnalyticsSummaryDiagnostics = .empty)
    {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.medianSessionDurationSeconds = medianSessionDurationSeconds
        self.medianToolCallsPerSession = medianToolCallsPerSession
        self.toolFailureRate = toolFailureRate
        self.topTools = topTools
        self.summaryDiagnostics = summaryDiagnostics
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
    private static let verificationPatternString =
        #"(?i)(?:\bxcodebuild\s+test\b|\bswift\s+test\b|\bcargo\s+test\b|\bnpm\s+test\b|"# +
        #"\bpnpm\s+test\b|\bbun\s+test\b|\bpytest\b|\bvitest\b|\bplaywright\b|"# +
        #"\blint\b|\bbuild\b|\btest\b)"#

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

        let sortedSessions = sessions.sorted(by: Self.isPreferredSession(_:_:))
        let recentSessions = Array(sortedSessions.prefix(maxSessions))
        guard !recentSessions.isEmpty else { return nil }

        let totalToolCalls = recentSessions.reduce(0) { $0 + $1.toolCallCount }
        let totalFailures = recentSessions.reduce(0) { $0 + $1.toolFailureCount }
        let medianDuration = Self.percentile(recentSessions.map(\.durationSeconds), percentile: 0.5)
        let medianToolCalls = Self.percentile(
            recentSessions.map { Double($0.toolCallCount) },
            percentile: 0.5)
        let toolFailureRate = totalToolCalls > 0 ? Double(totalFailures) / Double(totalToolCalls) : 0

        let allToolAggregates = Self.makeToolAggregates(from: recentSessions, totalToolCalls: totalToolCalls)
        let summaryDiagnostics = Self.makeSummaryDiagnostics(
            from: recentSessions,
            totalToolCalls: totalToolCalls,
            totalFailures: totalFailures,
            allToolAggregates: allToolAggregates)

        return CodexSessionAnalyticsSnapshot(
            generatedAt: now,
            sessions: recentSessions,
            medianSessionDurationSeconds: medianDuration,
            medianToolCallsPerSession: medianToolCalls,
            toolFailureRate: toolFailureRate,
            topTools: Array(allToolAggregates.prefix(5)),
            summaryDiagnostics: summaryDiagnostics)
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
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { return }
            Self.applyEventMessage(payload, type: payloadType, to: &state)

        case "response_item":
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { return }
            Self.applyResponseItem(payload, type: payloadType, to: &state)

        default:
            return
        }
    }

    private static func applyEventMessage(
        _ payload: [String: Any],
        type: String,
        to state: inout SessionAccumulator)
    {
        switch type {
        case "user_message":
            guard state.title == nil,
                  let message = payload["message"] as? String
            else { return }
            state.title = self.makeTitle(from: message)

        case "token_count":
            if let usage = self.parseTokenUsage(from: payload) {
                state.tokenUsage = usage
            }

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
                if let callID = payload["call_id"] as? String, !callID.isEmpty {
                    state.toolNamesByCallID[callID] = name
                }
            }
            if let commandText = commandText(from: payload),
               isVerificationAttempt(commandText)
            {
                state.verificationAttemptCount += 1
            }

        case "function_call_output":
            guard let output = payload["output"] as? String else { return }
            let failure = self.isFailureOutput(output)
            let longRunning = self.wallTimeSeconds(in: output) > 5

            if failure {
                state.toolFailureCount += 1
            }
            if longRunning {
                state.longRunningCallCount += 1
            }

            guard let callID = payload["call_id"] as? String,
                  let toolName = state.toolNamesByCallID[callID]
            else { return }

            if failure {
                state.toolFailureCountsByName[toolName, default: 0] += 1
            }
            if longRunning {
                state.toolLongRunningCountsByName[toolName, default: 0] += 1
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

    private static func parseTokenUsage(from payload: [String: Any]) -> CodexSessionTokenUsage? {
        guard let info = payload["info"] as? [String: Any],
              let totals = info["total_token_usage"] as? [String: Any]
        else { return nil }

        let totalTokens = self.toInt(totals["total_tokens"])
        guard totalTokens > 0 else { return nil }

        return CodexSessionTokenUsage(
            totalTokens: totalTokens,
            inputTokens: self.toInt(totals["input_tokens"]),
            cachedInputTokens: self.toInt(totals["cached_input_tokens"] ?? totals["cache_read_input_tokens"]),
            outputTokens: self.toInt(totals["output_tokens"]),
            reasoningOutputTokens: self.toInt(totals["reasoning_output_tokens"]))
    }

    private static func makeToolAggregates(
        from sessions: [CodexSessionSummary],
        totalToolCalls: Int) -> [CodexToolAggregate]
    {
        var callTotals: [String: Int] = [:]
        var sessionTotals: [String: Int] = [:]
        var maxCalls: [String: Int] = [:]
        var maxCallsSessionTitle: [String: String] = [:]
        var failureTotals: [String: Int] = [:]
        var failedSessionTotals: [String: Int] = [:]
        var longRunningTotals: [String: Int] = [:]

        for session in sessions {
            for (name, count) in session.toolCountsByName {
                callTotals[name, default: 0] += count
                sessionTotals[name, default: 0] += 1
                if count > maxCalls[name, default: 0] {
                    maxCalls[name] = count
                    maxCallsSessionTitle[name] = session.title
                }
            }

            for (name, failureCount) in session.toolFailureCountsByName {
                failureTotals[name, default: 0] += failureCount
                if failureCount > 0 {
                    failedSessionTotals[name, default: 0] += 1
                }
            }

            for (name, longRunningCount) in session.toolLongRunningCountsByName {
                longRunningTotals[name, default: 0] += longRunningCount
            }
        }

        return callTotals.map { name, callCount in
            let activeSessionCount = sessionTotals[name, default: 0]
            let failureCount = failureTotals[name, default: 0]
            return CodexToolAggregate(
                name: name,
                callCount: callCount,
                sessionCountUsingTool: activeSessionCount,
                callShare: totalToolCalls > 0 ? Double(callCount) / Double(totalToolCalls) : 0,
                averageCallsPerActiveSession: activeSessionCount > 0 ?
                    Double(callCount) / Double(activeSessionCount) : 0,
                maxCallsInSingleSession: maxCalls[name, default: 0],
                maxCallsSessionTitle: maxCallsSessionTitle[name],
                failureCount: failureCount,
                failureRate: callCount > 0 ? Double(failureCount) / Double(callCount) : 0,
                sessionsWithToolFailure: failedSessionTotals[name, default: 0],
                longRunningCount: longRunningTotals[name, default: 0])
        }
        .sorted {
            if $0.callCount != $1.callCount {
                return $0.callCount > $1.callCount
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func makeSummaryDiagnostics(
        from sessions: [CodexSessionSummary],
        totalToolCalls: Int,
        totalFailures: Int,
        allToolAggregates: [CodexToolAggregate]) -> CodexSessionAnalyticsSummaryDiagnostics
    {
        guard !sessions.isEmpty else { return .empty }

        let sortedStartedAt = sessions.map(\.startedAt).sorted()
        let sortedDurations = sessions.map(\.durationSeconds)
        let sortedToolCalls = sessions.map { Double($0.toolCallCount) }
        let durationSum = sessions.reduce(0.0) { $0 + $1.durationSeconds }
        let top3DurationSum = sessions
            .map(\.durationSeconds)
            .sorted(by: >)
            .prefix(3)
            .reduce(0, +)
        let topFailingTool = allToolAggregates
            .filter { $0.failureCount > 0 }
            .max(by: Self.isLowerPriorityTool(_:_:))

        return CodexSessionAnalyticsSummaryDiagnostics(
            windowSpanSeconds: max(
                0,
                sortedStartedAt.last?.timeIntervalSince(sortedStartedAt.first ?? .distantPast) ?? 0),
            sessionsWithTokens: sessions.count(where: { $0.tokenUsage != nil }),
            sessionsWithFailures: sessions.count(where: { $0.toolFailureCount > 0 }),
            sessionsWithChecks: sessions.count(where: { $0.verificationAttemptCount > 0 }),
            durationP25Seconds: self.percentile(sortedDurations, percentile: 0.25),
            durationP50Seconds: self.percentile(sortedDurations, percentile: 0.5),
            durationP75Seconds: self.percentile(sortedDurations, percentile: 0.75),
            longestSessionDurationSeconds: sortedDurations.max() ?? 0,
            top3DurationShare: durationSum > 0 ? top3DurationSum / durationSum : 0,
            avgToolCalls: sessions.isEmpty ? 0 : Double(totalToolCalls) / Double(sessions.count),
            toolCallsP75: self.percentile(sortedToolCalls, percentile: 0.75),
            sessionsOver50Calls: sessions.count(where: { $0.toolCallCount > 50 }),
            sessionsOver100Calls: sessions.count(where: { $0.toolCallCount > 100 }),
            maxToolCallsInSingleSession: sessions.map(\.toolCallCount).max() ?? 0,
            failedCalls: totalFailures,
            totalCalls: totalToolCalls,
            topFailingToolName: topFailingTool?.name,
            topFailingToolFailures: topFailingTool?.failureCount ?? 0)
    }

    private static func isPreferredSession(_ lhs: CodexSessionSummary, _ rhs: CodexSessionSummary) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id > rhs.id
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

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }

        let clamped = min(max(percentile, 0), 1)
        let position = Double(sorted.count - 1) * clamped
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    private static func toInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private static func isLowerPriorityTool(_ lhs: CodexToolAggregate, _ rhs: CodexToolAggregate) -> Bool {
        if lhs.failureCount != rhs.failureCount {
            return lhs.failureCount < rhs.failureCount
        }
        if lhs.callCount != rhs.callCount {
            return lhs.callCount < rhs.callCount
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
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
    var toolFailureCountsByName: [String: Int] = [:]
    var toolLongRunningCountsByName: [String: Int] = [:]
    var toolNamesByCallID: [String: String] = [:]
    var tokenUsage: CodexSessionTokenUsage?

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
            toolCountsByName: self.toolCountsByName,
            toolFailureCountsByName: self.toolFailureCountsByName,
            toolLongRunningCountsByName: self.toolLongRunningCountsByName,
            tokenUsage: self.tokenUsage)
    }
}
