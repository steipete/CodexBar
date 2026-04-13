import Foundation

public enum CodexSessionAnalyticsIndexIO {
    private static let artifactVersion = 1

    public static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("session-analytics", isDirectory: true)
            .appendingPathComponent("codex-v\(self.artifactVersion).json", isDirectory: false)
    }

    public static func load(cacheRoot: URL? = nil) -> CodexSessionAnalyticsIndex? {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let index = try? JSONDecoder().decode(CodexSessionAnalyticsIndex.self, from: data) else { return nil }
        guard index.version == self.artifactVersion else { return nil }
        return index
    }

    public static func save(index: CodexSessionAnalyticsIndex, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tmpURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(index)) ?? Data()

        do {
            try data.write(to: tmpURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }
}

public enum CodexSessionAnalyticsRootKind: String, Codable, Sendable {
    case active
    case archived
}

public struct CodexSessionAnalyticsIndexedFile: Sendable, Equatable, Codable {
    public let path: String
    public let sizeBytes: Int64
    public let mtimeUnixMs: Int64
    public let rootKind: CodexSessionAnalyticsRootKind
    public let session: CodexSessionSummary?

    public init(
        path: String,
        sizeBytes: Int64,
        mtimeUnixMs: Int64,
        rootKind: CodexSessionAnalyticsRootKind,
        session: CodexSessionSummary?)
    {
        self.path = path
        self.sizeBytes = sizeBytes
        self.mtimeUnixMs = mtimeUnixMs
        self.rootKind = rootKind
        self.session = session
    }
}

public struct CodexSessionAnalyticsIndex: Sendable, Equatable, Codable {
    public var version: Int
    public var lastSuccessfulRefreshAt: Date?
    public var lastDiscoveryAt: Date?
    public var dirty: Bool
    public var files: [String: CodexSessionAnalyticsIndexedFile]
    public var parseErrorsByPath: [String: String]

    public init(
        version: Int = 1,
        lastSuccessfulRefreshAt: Date? = nil,
        lastDiscoveryAt: Date? = nil,
        dirty: Bool = false,
        files: [String: CodexSessionAnalyticsIndexedFile] = [:],
        parseErrorsByPath: [String: String] = [:])
    {
        self.version = version
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastDiscoveryAt = lastDiscoveryAt
        self.dirty = dirty
        self.files = files
        self.parseErrorsByPath = parseErrorsByPath
    }
}

public struct CodexSessionAnalyticsIndexer: @unchecked Sendable {
    private let env: [String: String]
    private let fileManager: FileManager
    private let homeDirectoryURL: URL?
    private let cacheRoot: URL?
    private let parser: CodexSessionAnalyticsParser

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil,
        cacheRoot: URL? = nil)
    {
        self.env = env
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        self.cacheRoot = cacheRoot
        self.parser = CodexSessionAnalyticsParser()
    }

    public func loadPersistedIndex() -> CodexSessionAnalyticsIndex? {
        CodexSessionAnalyticsIndexIO.load(cacheRoot: self.cacheRoot)
    }

    public func persist(index: CodexSessionAnalyticsIndex) {
        CodexSessionAnalyticsIndexIO.save(index: index, cacheRoot: self.cacheRoot)
    }

    public func watchRoots() -> [URL] {
        [self.sessionsRoot(), self.archivedSessionsRoot()]
    }

    public func refreshIndex(
        existing: CodexSessionAnalyticsIndex?,
        now: Date = .now,
        persist: Bool = true) throws -> CodexSessionAnalyticsIndex
    {
        let priorIndex = existing ?? CodexSessionAnalyticsIndex()
        let candidates = self.rolloutCandidates()
        var files: [String: CodexSessionAnalyticsIndexedFile] = [:]
        files.reserveCapacity(candidates.count)

        var parseErrors: [String: String] = [:]
        parseErrors.reserveCapacity(priorIndex.parseErrorsByPath.count)

        for candidate in candidates {
            let cached = priorIndex.files[candidate.path]
            let shouldReparse =
                cached == nil ||
                cached?.sizeBytes != candidate.sizeBytes ||
                cached?.mtimeUnixMs != candidate.mtimeUnixMs ||
                priorIndex.parseErrorsByPath[candidate.path] != nil

            if !shouldReparse, let cached {
                files[candidate.path] = cached
                continue
            }

            do {
                let parsed = try self.parser.parseSessionFile(candidate.url)
                files[candidate.path] = candidate.indexedFile(session: parsed ?? cached?.session)
                if parsed == nil {
                    parseErrors[candidate.path] = "No valid session summary found."
                }
            } catch {
                files[candidate.path] = candidate.indexedFile(session: cached?.session)
                parseErrors[candidate.path] = error.localizedDescription
            }
        }

        let index = CodexSessionAnalyticsIndex(
            version: 1,
            lastSuccessfulRefreshAt: now,
            lastDiscoveryAt: now,
            dirty: false,
            files: files,
            parseErrorsByPath: parseErrors)
        if persist {
            self.persist(index: index)
        }
        return index
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

    private func sessionsRoot() -> URL {
        self.codexHomeRoot().appendingPathComponent("sessions", isDirectory: true)
    }

    private func archivedSessionsRoot() -> URL {
        self.codexHomeRoot().appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private func rolloutCandidates() -> [CodexSessionAnalyticsFileCandidate] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let roots: [(URL, CodexSessionAnalyticsRootKind)] = [
            (self.sessionsRoot(), .active),
            (self.archivedSessionsRoot(), .archived),
        ]

        var candidates: [CodexSessionAnalyticsFileCandidate] = []
        candidates.reserveCapacity(64)

        for (root, rootKind) in roots {
            guard self.fileManager.fileExists(atPath: root.path),
                  let enumerator = self.fileManager.enumerator(
                      at: root,
                      includingPropertiesForKeys: Array(keys),
                      options: options)
            else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension.lowercased() == "jsonl"
                else { continue }

                let resourceValues = try? fileURL.resourceValues(forKeys: keys)
                guard resourceValues?.isRegularFile != false else { continue }

                let mtimeUnixMs = Int64((resourceValues?.contentModificationDate ?? .distantPast)
                    .timeIntervalSince1970 * 1000)
                let sizeBytes = Int64(resourceValues?.fileSize ?? 0)
                candidates.append(CodexSessionAnalyticsFileCandidate(
                    url: fileURL,
                    path: fileURL.path,
                    sizeBytes: sizeBytes,
                    mtimeUnixMs: mtimeUnixMs,
                    rootKind: rootKind))
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.mtimeUnixMs != rhs.mtimeUnixMs {
                return lhs.mtimeUnixMs > rhs.mtimeUnixMs
            }
            if lhs.rootKind != rhs.rootKind {
                return lhs.rootKind == .active
            }
            return lhs.path < rhs.path
        }
    }
}

public enum CodexSessionAnalyticsSnapshotBuilder {
    public static func buildSnapshots(
        from index: CodexSessionAnalyticsIndex,
        windowSizes: [Int],
        now: Date = .now) -> [Int: CodexSessionAnalyticsSnapshot]
    {
        let uniqueWindowSizes = Array(Set(windowSizes.filter { $0 > 0 })).sorted()
        guard !uniqueWindowSizes.isEmpty else { return [:] }

        return Dictionary(uniqueKeysWithValues: uniqueWindowSizes.compactMap { windowSize in
            self.buildSnapshot(from: index, maxSessions: windowSize, now: now).map { (windowSize, $0) }
        })
    }

    public static func buildSnapshot(
        from index: CodexSessionAnalyticsIndex,
        maxSessions: Int,
        now: Date = .now) -> CodexSessionAnalyticsSnapshot?
    {
        guard maxSessions > 0 else { return nil }

        let recentSessions = Array(self.resolvedSessions(from: index).prefix(maxSessions))
        guard !recentSessions.isEmpty else { return nil }

        let generatedAt = index.lastSuccessfulRefreshAt ?? now
        let totalToolCalls = recentSessions.reduce(0) { $0 + $1.toolCallCount }
        let totalFailures = recentSessions.reduce(0) { $0 + $1.toolFailureCount }
        let medianDuration = self.percentile(recentSessions.map(\.durationSeconds), percentile: 0.5)
        let medianToolCalls = self.percentile(
            recentSessions.map { Double($0.toolCallCount) },
            percentile: 0.5)
        let toolFailureRate = totalToolCalls > 0 ? Double(totalFailures) / Double(totalToolCalls) : 0

        let allToolAggregates = self.makeToolAggregates(from: recentSessions, totalToolCalls: totalToolCalls)
        let summaryDiagnostics = self.makeSummaryDiagnostics(
            from: recentSessions,
            totalToolCalls: totalToolCalls,
            totalFailures: totalFailures,
            allToolAggregates: allToolAggregates)

        return CodexSessionAnalyticsSnapshot(
            generatedAt: generatedAt,
            sessions: recentSessions,
            medianSessionDurationSeconds: medianDuration,
            medianToolCallsPerSession: medianToolCalls,
            toolFailureRate: toolFailureRate,
            topTools: Array(allToolAggregates.prefix(5)),
            summaryDiagnostics: summaryDiagnostics)
    }

    private static func resolvedSessions(from index: CodexSessionAnalyticsIndex) -> [CodexSessionSummary] {
        var chosenBySessionID: [String: CodexSessionAnalyticsIndexedFile] = [:]

        for file in index.files.values {
            guard let session = file.session else { continue }
            if let existing = chosenBySessionID[session.id] {
                if self.isPreferredIndexedFile(file, over: existing) {
                    chosenBySessionID[session.id] = file
                }
            } else {
                chosenBySessionID[session.id] = file
            }
        }

        return chosenBySessionID.values
            .compactMap(\.session)
            .sorted(by: self.isPreferredSession(_:_:))
    }

    private static func isPreferredIndexedFile(
        _ lhs: CodexSessionAnalyticsIndexedFile,
        over rhs: CodexSessionAnalyticsIndexedFile) -> Bool
    {
        if lhs.mtimeUnixMs != rhs.mtimeUnixMs {
            return lhs.mtimeUnixMs > rhs.mtimeUnixMs
        }
        if lhs.rootKind != rhs.rootKind {
            return lhs.rootKind == .active
        }
        return lhs.path < rhs.path
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
            .max(by: self.isLowerPriorityTool(_:_:))

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

    private static func isPreferredSession(_ lhs: CodexSessionSummary, _ rhs: CodexSessionSummary) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id > rhs.id
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

public struct CodexSessionAnalyticsParser: @unchecked Sendable {
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

    public init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = formatter
    }

    public func parseSessionFile(_ fileURL: URL) throws -> CodexSessionSummary? {
        var state = SessionAccumulator()

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

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let parsed = self.iso8601Formatter.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
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
            if let commandText = self.commandText(from: payload),
               self.isVerificationAttempt(commandText)
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

    static func fallbackTitle(for fileURL: URL) -> String {
        let base = fileURL.deletingPathExtension().lastPathComponent
        if base.hasPrefix("rollout-") {
            return String(base.dropFirst("rollout-".count))
        }
        return base
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
        guard let regex = self.verificationPattern else { return false }
        let range = NSRange(commandText.startIndex..<commandText.endIndex, in: commandText)
        return regex.firstMatch(in: commandText, range: range) != nil
    }

    private static func isFailureOutput(_ output: String) -> Bool {
        if output.localizedCaseInsensitiveContains("tool call error:") {
            return true
        }

        guard let regex = self.nonZeroExitPattern else { return false }
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
        guard let regex = self.wallTimePattern else { return 0 }
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

    private static func toInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }
}

private struct CodexSessionAnalyticsFileCandidate {
    let url: URL
    let path: String
    let sizeBytes: Int64
    let mtimeUnixMs: Int64
    let rootKind: CodexSessionAnalyticsRootKind

    func indexedFile(session: CodexSessionSummary?) -> CodexSessionAnalyticsIndexedFile {
        CodexSessionAnalyticsIndexedFile(
            path: self.path,
            sizeBytes: self.sizeBytes,
            mtimeUnixMs: self.mtimeUnixMs,
            rootKind: self.rootKind,
            session: session)
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
            title: self.title ?? CodexSessionAnalyticsParser.fallbackTitle(for: fileURL),
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
