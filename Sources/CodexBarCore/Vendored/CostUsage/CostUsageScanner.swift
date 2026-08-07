#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Dispatch
import Foundation

// swiftlint:disable type_body_length file_length
enum CostUsageScanner {
    static let codexProjectMetadataVersion = 1
    typealias CancellationCheck = () throws -> Void

    static let log = CodexBarLog.logger(LogCategories.tokenCost)
    static let codexActiveSessionLookbackDays = 30
    static let costScale = 1_000_000_000.0
    /// Reserved cache marker. Resolver-produced dependencies use `file|...` or `missing:...`;
    /// this value records that lineage exists but this rollout owns its counter or suffix.
    static let codexForkDependencyNotRequiredKey = "mode:lineage-only:v1"

    /// Resolved dependency keys include a diagnostic path plus an authoritative source stamp.
    /// Treat raw-path and canonical-path spellings as the same generation only when the session
    /// ID and complete file identity suffix agree. This lets an in-progress cache rebind `/var`
    /// to `/private/var` (or a symlink to its target) without restarting its child body.
    static func codexResolvedForkDependencyKeysMatch(
        _ lhs: String,
        _ rhs: String) -> Bool
    {
        if lhs == rhs { return true }
        struct Identity: Equatable {
            let sessionID: Substring
            let fileID: Substring
            let mtime: Substring
            let size: Substring
            let changeTime: Substring?
        }
        func identity(_ key: String) -> Identity? {
            let fields = key.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.first == "file" else { return nil }
            switch fields.count {
            case 7:
                return Identity(
                    sessionID: fields[1],
                    fileID: fields[3],
                    mtime: fields[4],
                    size: fields[5],
                    changeTime: fields[6])
            case 6:
                return Identity(
                    sessionID: fields[1],
                    fileID: fields[3],
                    mtime: fields[4],
                    size: fields[5],
                    changeTime: nil)
            default:
                // Historical keys did not escape `|` inside paths, so ambiguous shapes cannot
                // be rebound safely. Exact equality above remains valid for those rare paths.
                return nil
            }
        }
        guard let left = identity(lhs),
              let right = identity(rhs),
              left.sessionID == right.sessionID,
              left.fileID != "unknown",
              left.fileID == right.fileID,
              left.mtime == right.mtime,
              left.size == right.size
        else { return false }
        // A six-field predecessor key lacks ctime. It cannot distinguish an append-only source
        // from an in-place same-size rewrite whose mtime was restored, so it must rebuild once
        // before a partial child's normalized accounting state can be resumed safely.
        guard let leftChangeTime = left.changeTime,
              let rightChangeTime = right.changeTime
        else { return false }
        return leftChangeTime == rightChangeTime
    }

    final class CodexSessionHeadParseObserverStore: @unchecked Sendable {
        let observer: () -> Void

        init(observer: @escaping () -> Void) {
            self.observer = observer
        }
    }

    @TaskLocal private static var codexSessionHeadParseObserverStore: CodexSessionHeadParseObserverStore?

    static func withCodexSessionHeadParseObserverForTesting<T>(
        _ observer: @escaping () -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$codexSessionHeadParseObserverStore.withValue(.init(observer: observer)) {
            try operation()
        }
    }

    final class CodexInheritedTotalsParseOverrideStore: @unchecked Sendable {
        let resolve: (String, String) -> CodexForkBaseline?

        init(resolve: @escaping (String, String) -> CodexForkBaseline?) {
            self.resolve = resolve
        }
    }

    @TaskLocal private static var codexInheritedTotalsParseOverrideStore:
        CodexInheritedTotalsParseOverrideStore?

    /// Deterministically injects a parser-only parent lookup result. Dependency preflight still
    /// uses the real resolver, which lets tests cover availability changing between the two reads.
    static func withCodexInheritedTotalsParseOverrideForTesting<T>(
        _ resolve: @escaping (String, String) -> CodexForkBaseline?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$codexInheritedTotalsParseOverrideStore.withValue(.init(resolve: resolve)) {
            try operation()
        }
    }

    static func codexInheritedTotalsForParsing(
        parentSessionId: String,
        cutoffTimestamp: String,
        fallback: () throws -> CodexForkBaseline) rethrows -> CodexForkBaseline
    {
        if let overridden = self.codexInheritedTotalsParseOverrideStore?
            .resolve(parentSessionId, cutoffTimestamp)
        {
            return overridden
        }
        return try fallback()
    }

    final class CodexBeforeFileUsagePublicationHookStore: @unchecked Sendable {
        let hook: (URL) -> Void

        init(hook: @escaping (URL) -> Void) {
            self.hook = hook
        }
    }

    @TaskLocal private static var codexBeforeFileUsagePublicationHookStore:
        CodexBeforeFileUsagePublicationHookStore?

    /// Runs after token-index persistence but before the JSON cursor and aggregate cache are
    /// published. Tests use this seam to replace a source at the narrowest commit boundary.
    static func withCodexBeforeFileUsagePublicationHookForTesting<T>(
        _ hook: @escaping (URL) -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$codexBeforeFileUsagePublicationHookStore.withValue(.init(hook: hook)) {
            try operation()
        }
    }

    static func notifyCodexBeforeFileUsagePublicationForTesting(fileURL: URL) {
        self.codexBeforeFileUsagePublicationHookStore?.hook(fileURL)
    }

    final class CodexAfterFileParseHookStore: @unchecked Sendable {
        let hook: (URL) -> Void

        init(hook: @escaping (URL) -> Void) {
            self.hook = hook
        }
    }

    @TaskLocal private static var codexAfterFileParseHookStore: CodexAfterFileParseHookStore?

    /// Runs after the fixed-high-water parser returns and before source/SQLite validation. This
    /// seam makes an append-during-read race deterministic without coupling tests to throughput.
    static func withCodexAfterFileParseHookForTesting<T>(
        _ hook: @escaping (URL) -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$codexAfterFileParseHookStore.withValue(.init(hook: hook)) {
            try operation()
        }
    }

    static func notifyCodexAfterFileParseForTesting(fileURL: URL) {
        self.codexAfterFileParseHookStore?.hook(fileURL)
    }

    struct CodexScanWorkMetrics: Equatable, Sendable {
        let budgetBytesConsumed: Int64
        let fileBodyBudgetBytesConsumed: Int64
        let fileParseInvocations: Int
        let usageRowsRead: Int
        let usageRowDeltaProcessed: Int
        let usageRowsWritten: Int
        let usageRowsRepriced: Int
        let usageRowsFingerprintHashed: Int
    }

    /// Opt-in instrumentation used by proof and regression tests. Keeping this as a recorder on
    /// `Options` (rather than a task local) is intentional: production scans cross onto the
    /// dedicated Dispatch queue, where Swift task-local values are not inherited.
    final class CodexScanWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedBudgetBytes: Int64 = 0
        private var recordedFileBodyBudgetBytes: Int64 = 0
        private var recordedFileParses = 0
        private var recordedUsageRowsRead = 0
        private var recordedUsageRowDeltaProcessed = 0
        private var recordedUsageRowsWritten = 0
        private var recordedUsageRowsRepriced = 0
        private var recordedUsageRowsFingerprintHashed = 0

        // swiftlint:disable:next function_parameter_count
        func record(
            budgetBytesConsumed: Int64,
            fileBodyBudgetBytesConsumed: Int64,
            fileParseInvocations: Int,
            usageRowsRead: Int,
            usageRowDeltaProcessed: Int,
            usageRowsWritten: Int,
            usageRowsRepriced: Int,
            usageRowsFingerprintHashed: Int)
        {
            self.lock.lock()
            self.recordedBudgetBytes += max(0, budgetBytesConsumed)
            self.recordedFileBodyBudgetBytes += max(0, fileBodyBudgetBytesConsumed)
            self.recordedFileParses += max(0, fileParseInvocations)
            self.recordedUsageRowsRead += max(0, usageRowsRead)
            self.recordedUsageRowDeltaProcessed += max(0, usageRowDeltaProcessed)
            self.recordedUsageRowsWritten += max(0, usageRowsWritten)
            self.recordedUsageRowsRepriced += max(0, usageRowsRepriced)
            self.recordedUsageRowsFingerprintHashed += max(0, usageRowsFingerprintHashed)
            self.lock.unlock()
        }

        func snapshot() -> CodexScanWorkMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return CodexScanWorkMetrics(
                budgetBytesConsumed: self.recordedBudgetBytes,
                fileBodyBudgetBytesConsumed: self.recordedFileBodyBudgetBytes,
                fileParseInvocations: self.recordedFileParses,
                usageRowsRead: self.recordedUsageRowsRead,
                usageRowDeltaProcessed: self.recordedUsageRowDeltaProcessed,
                usageRowsWritten: self.recordedUsageRowsWritten,
                usageRowsRepriced: self.recordedUsageRowsRepriced,
                usageRowsFingerprintHashed: self.recordedUsageRowsFingerprintHashed)
        }
    }

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        /// Stable cache-family root used only for the cross-process clear barrier. Spend
        /// Dashboard account caches share the live cache root while retaining local writer locks.
        var codexRefreshLockRoot: URL?
        var codexTraceDatabaseURL: URL?
        var calendar: Calendar
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false
        /// Maximum bounded slice read from one Codex rollout per refresh. Larger files
        /// resume from cached progress on later refreshes. Default 256 MiB.
        var maxCodexSessionFileBytes: Int64 = 256 * 1024 * 1024
        /// Soft budget for newly-read Codex session bytes in one refresh.
        /// Remaining dirty files are deferred to later refreshes. Default 512 MiB.
        var maxCodexScanBytesPerRefresh: Int64 = 512 * 1024 * 1024
        /// Optional wall-clock budget for newly-read Codex bytes in one refresh. The reader
        /// finishes its current 256 KiB chunk, persists resume state, and continues later.
        var maxCodexScanDurationPerRefresh: TimeInterval?
        /// Prefer newest session files first so recent usage lands before catch-up work.
        var preferNewestCodexSessionsFirst: Bool = true
        /// Test-only recorder for the scanner's actual per-refresh work accounting.
        var codexScanWorkRecorderForTesting: CodexScanWorkRecorder?

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            codexRefreshLockRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            calendar: Calendar = .current,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false,
            maxCodexSessionFileBytes: Int64 = 256 * 1024 * 1024,
            maxCodexScanBytesPerRefresh: Int64 = 512 * 1024 * 1024,
            maxCodexScanDurationPerRefresh: TimeInterval? = nil,
            preferNewestCodexSessionsFirst: Bool = true,
            codexScanWorkRecorderForTesting: CodexScanWorkRecorder? = nil)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.codexRefreshLockRoot = codexRefreshLockRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.calendar = calendar
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
            self.maxCodexSessionFileBytes = max(0, maxCodexSessionFileBytes)
            self.maxCodexScanBytesPerRefresh = max(0, maxCodexScanBytesPerRefresh)
            self.maxCodexScanDurationPerRefresh = maxCodexScanDurationPerRefresh.map { max(0, $0) }
            self.preferNewestCodexSessionsFirst = preferNewestCodexSessionsFirst
            self.codexScanWorkRecorderForTesting = codexScanWorkRecorderForTesting
        }
    }

    /// Per-refresh work limiter for Codex cost scans. Prevents multi-GB rollout corpora from
    /// monopolizing a core for hours while still allowing progressive catch-up.
    final class CodexScanBudget: @unchecked Sendable {
        let maxFileBytes: Int64
        let maxBytesPerRefresh: Int64
        private(set) var bytesConsumed: Int64 = 0
        private(set) var resumedPartialFileCount = 0
        private(set) var deferredByBudgetFileCount = 0
        private(set) var deferredByTimeBudgetFileCount = 0
        private(set) var deferredBySourceMutationFileCount = 0
        private(set) var deferredByPersistenceFileCount = 0
        private(set) var fileBodyBudgetBytesConsumed: Int64 = 0
        private(set) var fileParseInvocationCount = 0
        private(set) var usageRowsRead = 0
        private(set) var usageRowDeltaProcessed = 0
        private(set) var usageRowsWritten = 0
        private(set) var usageRowsRepriced = 0
        private(set) var usageRowsFingerprintHashed = 0
        private var bytesReserved: Int64 = 0
        private let deadline: ContinuousClock.Instant?
        private let now: @Sendable () -> ContinuousClock.Instant
        private var recordedTimeDeferral = false

        init(
            maxFileBytes: Int64,
            maxBytesPerRefresh: Int64,
            maxDuration: TimeInterval? = nil,
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now })
        {
            self.maxFileBytes = max(0, maxFileBytes)
            self.maxBytesPerRefresh = max(0, maxBytesPerRefresh)
            self.now = now
            if let maxDuration, maxDuration > 0 {
                self.deadline = now().advanced(by: .seconds(maxDuration))
            } else {
                self.deadline = nil
            }
        }

        var hasTimeLimit: Bool {
            self.deadline != nil
        }

        enum Admission {
            case allow(Int64)
            case deferBudget
        }

        func admit(workBytes: Int64, recordPartialWork: Bool = true) -> Admission {
            let work = max(0, workBytes)
            if work > 0, self.shouldYield(additionalBytes: 0) {
                self.deferredByBudgetFileCount += 1
                return .deferBudget
            }
            let refreshRemaining = self.maxBytesPerRefresh > 0
                ? max(0, self.maxBytesPerRefresh - self.bytesConsumed - self.bytesReserved)
                : Int64.max
            if work > 0, refreshRemaining == 0 {
                self.deferredByBudgetFileCount += 1
                return .deferBudget
            }
            let fileAllowance = self.maxFileBytes > 0 ? self.maxFileBytes : Int64.max
            let allowance = min(work, fileAllowance, refreshRemaining)
            if allowance < work, recordPartialWork {
                self.resumedPartialFileCount += 1
            }
            self.bytesReserved += allowance
            return .allow(allowance)
        }

        func consume(workBytes: Int64) {
            let work = max(0, workBytes)
            self.bytesReserved = max(0, self.bytesReserved - work)
            self.bytesConsumed += work
        }

        func consumeFileBody(workBytes: Int64) {
            let work = max(0, workBytes)
            self.consume(workBytes: work)
            self.fileBodyBudgetBytesConsumed += work
        }

        func release(workBytes: Int64) {
            self.bytesReserved = max(0, self.bytesReserved - max(0, workBytes))
        }

        func complete(admittedWorkBytes: Int64, actualWorkBytes: Int64) {
            let admitted = max(0, admittedWorkBytes)
            let actual = min(admitted, max(0, actualWorkBytes))
            self.consume(workBytes: actual)
            self.release(workBytes: admitted - actual)
        }

        func shouldYield(additionalBytes: Int64) -> Bool {
            guard let deadline else { return false }
            guard self.bytesConsumed + self.bytesReserved + max(0, additionalBytes) > 0 else { return false }
            guard self.now() >= deadline else { return false }
            if !self.recordedTimeDeferral {
                self.recordedTimeDeferral = true
                self.deferredByTimeBudgetFileCount += 1
            }
            return true
        }

        func recordSourceMutationDeferral() {
            self.deferredBySourceMutationFileCount += 1
        }

        func recordPersistenceDeferral() {
            self.deferredByPersistenceFileCount += 1
        }

        func recordPartialWork() {
            self.resumedPartialFileCount += 1
        }

        func recordFileParseInvocation() {
            self.fileParseInvocationCount += 1
        }

        func recordUsageRowWork(
            read: Int = 0,
            deltaProcessed: Int = 0,
            written: Int = 0,
            repriced: Int = 0,
            fingerprintHashed: Int = 0)
        {
            self.usageRowsRead += max(0, read)
            self.usageRowDeltaProcessed += max(0, deltaProcessed)
            self.usageRowsWritten += max(0, written)
            self.usageRowsRepriced += max(0, repriced)
            self.usageRowsFingerprintHashed += max(0, fingerprintHashed)
        }
    }

    struct CodexParseResult {
        let days: [String: [String: [Int]]]
        var parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let lastCountedTotals: CostUsageCodexTotals?
        let lastRawTotalsBaseline: CostUsageCodexTotals?
        let lastRawTotalsWatermark: CostUsageCodexTotals?
        let seenRawTotals: [CostUsageCodexTotals]
        let hasDivergentTotals: Bool
        let hasInterleavedTotals: Bool
        let lastCodexTurnID: String?
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
        let dependsOnParentTotals: Bool
        let projectPath: String?
        let codexSession: CostUsageCodexSessionMetadata
        let rows: [CodexUsageRow]
        let nextUsageRowIndex: Int
        let tokenSnapshots: [CostUsageCodexTokenSnapshot]
        let jsonlResumeState: CostUsageJsonl.ResumeState?
        let bufferedSubagentLines: [CodexBufferedFastLine]?
        let subagentResumeState: CostUsageCodexSubagentResumeState?
        let deferredReplayState: CostUsageCodexDeferredReplayState?
        let bufferedUnresolvedForkLines: [CodexBufferedFastLine]?
        let forkAccountingState: CostUsageCodexForkAccountingState?
    }

    /// Authoritative ordinary-fork context carried across bounded body slices. Without it a
    /// suffix starts after `session_meta`, loses the parent identity, and treats cumulative child
    /// totals as a fresh non-fork counter.
    struct CodexOrdinaryForkResumeContext {
        let sessionId: String?
        let parentSessionId: String
        let forkTimestamp: String
        let projectPath: String?
        let codexSession: CostUsageCodexSessionMetadata?
        let accountingState: CostUsageCodexForkAccountingState
    }

    /// Authoritative protocol-delimited subagent context carried across bounded slices and
    /// completed-file appends. Unlike legacy shape inference, later appended metadata cannot move
    /// this boundary, so the validated JSON prefix is safe to resume.
    struct CodexOrdinalSubagentResumeContext {
        let sessionId: String?
        let parentSessionId: String?
        let forkTimestamp: String?
        let projectPath: String?
        let codexSession: CostUsageCodexSessionMetadata?
        let state: CostUsageCodexSubagentResumeState
    }

    struct CodexDeferredReplayContext {
        let sessionId: String?
        let parentSessionId: String?
        let forkTimestamp: String?
        let projectPath: String?
        let codexSession: CostUsageCodexSessionMetadata?
        let state: CostUsageCodexDeferredReplayState
    }

    struct CodexUsageRow: Codable, Equatable {
        let day: String
        let model: String
        let rawModel: String?
        let turnID: String?
        let eventIndex: Int?
        let timestampUnixMs: Int64?
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int?
        let knownCostNanos: Int64?
        let unpricedTokens: Int?
        let pricingModel: String?
        let pricingMode: String?

        init(
            day: String,
            model: String,
            rawModel: String? = nil,
            turnID: String?,
            eventIndex: Int?,
            timestampUnixMs: Int64? = nil,
            input: Int,
            cached: Int,
            output: Int,
            reasoning: Int? = nil,
            knownCostNanos: Int64? = nil,
            unpricedTokens: Int? = nil,
            pricingModel: String? = nil,
            pricingMode: String? = nil)
        {
            self.day = day
            self.model = model
            self.rawModel = rawModel
            self.turnID = turnID
            self.eventIndex = eventIndex
            self.timestampUnixMs = timestampUnixMs
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning.map { min(max(0, $0), max(0, output)) }
            self.knownCostNanos = knownCostNanos
            self.unpricedTokens = unpricedTokens
            self.pricingModel = pricingModel
            self.pricingMode = pricingMode
        }
    }

    struct CodexScanState {
        var contributingSessionIds: Set<String> = []
        var authoritativeForkSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
        var seenCodexUsageRowKeys: Set<String> = []
    }

    struct CodexScannedSession {
        let id: String?
        let contributedUsage: Bool

        init(id: String?, days: [String: [String: [Int]]]) {
            self.id = id
            self.contributedUsage = !days.isEmpty
        }
    }

    private struct CodexTimestampedTotals {
        let timestamp: String
        let date: Date?
        let totals: CostUsageCodexTotals
    }

    enum CodexForkBaseline {
        case resolved(CostUsageCodexTotals?)
        case unresolved
    }

    private static func codexTotalsEqual(_ lhs: CostUsageCodexTotals?, _ rhs: CostUsageCodexTotals?) -> Bool {
        lhs?.input == rhs?.input && lhs?.cached == rhs?.cached && lhs?.output == rhs?.output
    }

    private static func codexTotalsAtLeast(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input >= rhs.input && lhs.cached >= rhs.cached && lhs.output >= rhs.output
    }

    private static func codexTotalsAtMost(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
        lhs.input <= rhs.input && lhs.cached <= rhs.cached && lhs.output <= rhs.output
    }

    private static func codexShouldPreferTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        currentTotal: CostUsageCodexTotals,
        totalDelta: CostUsageCodexTotals,
        lastDelta: CostUsageCodexTotals,
        sawDivergentTotals: Bool) -> Bool
    {
        guard !sawDivergentTotals, let rawBaseline else { return false }
        return Self.codexTotalsAtLeast(currentTotal, rawBaseline)
            && Self.codexTotalsAtMost(totalDelta, lastDelta)
    }

    private static func codexAddTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output,
            reasoning: self.codexAddOptional(lhs.reasoning, rhs.reasoning))
    }

    private static func codexMinTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: min(lhs.input, rhs.input),
            cached: min(lhs.cached, rhs.cached),
            output: min(lhs.output, rhs.output),
            reasoning: self.codexMinOptional(lhs.reasoning, rhs.reasoning))
    }

    private static func codexTotalDelta(
        from baseline: CostUsageCodexTotals?,
        to current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let reasoning = Self.codexOptionalDelta(
            from: baseline?.reasoning,
            to: current.reasoning,
            hasBaseline: baseline != nil)
        let baseline = baseline ?? .init(input: 0, cached: 0, output: 0)
        return CostUsageCodexTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output),
            reasoning: reasoning)
    }

    private static func codexDivergentTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        countedBaseline: CostUsageCodexTotals?,
        current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let rawBaseline = rawBaseline ?? .init(input: 0, cached: 0, output: 0)
        let countedBaseline = countedBaseline ?? .init(input: 0, cached: 0, output: 0)

        func delta(raw: Int, counted: Int, current: Int) -> Int {
            if current >= raw {
                return max(0, current - raw)
            }
            return max(0, current - counted)
        }

        return CostUsageCodexTotals(
            input: delta(raw: rawBaseline.input, counted: countedBaseline.input, current: current.input),
            cached: delta(raw: rawBaseline.cached, counted: countedBaseline.cached, current: current.cached),
            output: delta(raw: rawBaseline.output, counted: countedBaseline.output, current: current.output),
            reasoning: Self.codexDivergentOptionalDelta(
                raw: rawBaseline.reasoning,
                counted: countedBaseline.reasoning,
                current: current.reasoning))
    }

    private static func codexMaxTotals(
        _ lhs: CostUsageCodexTotals?,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        guard let lhs else { return rhs }
        return CostUsageCodexTotals(
            input: max(lhs.input, rhs.input),
            cached: max(lhs.cached, rhs.cached),
            output: max(lhs.output, rhs.output),
            reasoning: Self.codexMaxOptional(lhs.reasoning, rhs.reasoning))
    }

    /// Post-latch totals containment for interleaved cumulative counters (issue #2037 Phase 1).
    ///
    /// - When `current` is below the watermark, resume from the counted baseline so #968-style
    ///   recovery still works (`current - counted`).
    /// - When `current` is at/above the watermark, advance from `max(watermark, counted)` so a
    ///   high/low lineage flip cannot re-count the gap between lineages.
    private static func codexContainedTotalDelta(
        watermark: CostUsageCodexTotals?,
        counted: CostUsageCodexTotals?,
        current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let watermark = watermark ?? .init(input: 0, cached: 0, output: 0)
        let counted = counted ?? .init(input: 0, cached: 0, output: 0)

        func component(water: Int, counted: Int, current: Int) -> Int {
            if current >= water {
                return max(0, current - max(water, counted))
            }
            return max(0, current - counted)
        }

        return CostUsageCodexTotals(
            input: component(water: watermark.input, counted: counted.input, current: current.input),
            cached: component(water: watermark.cached, counted: counted.cached, current: current.cached),
            output: component(water: watermark.output, counted: counted.output, current: current.output),
            reasoning: Self.codexContainedOptionalDelta(
                water: watermark.reasoning,
                counted: counted.reasoning,
                current: current.reasoning))
    }

    private static func codexAddOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    private static func codexMinOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return min(lhs, rhs)
    }

    private static func codexMaxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func codexSubtractOptional(_ value: Int?, _ baseline: Int?) -> Int? {
        guard let value, let baseline else { return nil }
        return max(0, value - baseline)
    }

    private static func codexOptionalDelta(from baseline: Int?, to current: Int?, hasBaseline: Bool) -> Int? {
        guard let current else { return nil }
        if !hasBaseline {
            return current
        }
        guard let baseline else { return nil }
        return max(0, current - baseline)
    }

    private static func codexDivergentOptionalDelta(raw: Int?, counted: Int?, current: Int?) -> Int? {
        guard let raw, let counted, let current else { return nil }
        if current >= raw {
            return max(0, current - raw)
        }
        return max(0, current - counted)
    }

    private static func codexContainedOptionalDelta(water: Int?, counted: Int?, current: Int?) -> Int? {
        guard let water, let counted, let current else { return nil }
        if current >= water {
            return max(0, current - max(water, counted))
        }
        return max(0, current - counted)
    }

    /// Post-latch event delta: contained totals growth, optionally capped by `last`.
    ///
    /// `last` alone must never increase counted usage when the contained totals delta is zero
    /// (smaller lineage below the watermark is an accepted Phase 1 undercount).
    private static func codexPostLatchEventDelta(
        watermark: CostUsageCodexTotals?,
        counted: CostUsageCodexTotals?,
        current: CostUsageCodexTotals,
        adjustedLast: CostUsageCodexTotals?) -> CostUsageCodexTotals
    {
        let contained = Self.codexContainedTotalDelta(
            watermark: watermark,
            counted: counted,
            current: current)
        guard let adjustedLast else { return contained }
        return Self.codexMinTotals(adjustedLast, contained)
    }

    /// Shared accounting guard for cumulative Codex token counters (issue #2037).
    ///
    /// Ultra-mode sessions interleave cumulative snapshots from several fork lineages inside one
    /// session file. The tracker keeps a monotonic high watermark (never lowered). After a drop
    /// latches interleaved mode, deltas use `codexPostLatchEventDelta` so gap recounting is
    /// impossible. `seenRawTotals` is an optional precision optimization for exact re-emissions;
    /// correctness does not depend on it once post-latch containment is active.
    struct CodexTotalsTracker {
        static let seenRawTotalsLimit = 64

        private(set) var watermark: CostUsageCodexTotals?
        private(set) var seenRawTotals: [CostUsageCodexTotals]
        private(set) var sawInterleavedTotals: Bool

        init(
            watermark: CostUsageCodexTotals? = nil,
            seenRawTotals: [CostUsageCodexTotals] = [],
            sawInterleavedTotals: Bool = false)
        {
            self.watermark = watermark
            self.seenRawTotals = Array(seenRawTotals.suffix(Self.seenRawTotalsLimit))
            self.sawInterleavedTotals = sawInterleavedTotals
        }

        func isSeen(_ totals: CostUsageCodexTotals) -> Bool {
            self.seenRawTotals.contains { CostUsageScanner.codexTotalsEqual($0, totals) }
        }

        /// Latches interleaved mode when any component of an observed cumulative snapshot drops
        /// strictly below the watermark. A monotonic counter cannot decrease, so a drop means either
        /// a second lineage or a reset; both must stop trusting gap-sized totals deltas.
        mutating func latchIfBelowWatermark(_ totals: CostUsageCodexTotals) {
            guard let watermark = self.watermark else { return }
            if totals.input < watermark.input
                || totals.cached < watermark.cached
                || totals.output < watermark.output
            {
                self.sawInterleavedTotals = true
            }
        }

        /// Records an observed cumulative snapshot: raises the watermark and remembers the exact
        /// value for best-effort re-emission suppression. Call after computing the event's delta.
        mutating func commitObserved(_ totals: CostUsageCodexTotals) {
            self.raiseWatermark(to: totals)
            if !self.seenRawTotals.contains(where: { CostUsageScanner.codexTotalsEqual($0, totals) }) {
                self.seenRawTotals.append(totals)
                if self.seenRawTotals.count > Self.seenRawTotalsLimit {
                    self.seenRawTotals.removeFirst(self.seenRawTotals.count - Self.seenRawTotalsLimit)
                }
            }
        }

        /// Raises the watermark for baseline assignments that are not observed raw snapshots
        /// (for example counted totals in last-only streams). Never lowers it.
        mutating func raiseWatermark(to totals: CostUsageCodexTotals) {
            self.watermark = CostUsageScanner.codexMaxTotals(self.watermark, totals)
        }
    }

    /// Cumulative-totals accounting for parent-session snapshot building. Applies the same
    /// containment policy as `parseCodexFileCancellable` so fork children inherit baselines
    /// computed under identical rules.
    struct CodexSnapshotAccumulator {
        var countedTotals: CostUsageCodexTotals?
        var rawTotalsBaseline: CostUsageCodexTotals?
        var sawDivergentTotals = false
        var tracker = CodexTotalsTracker()

        init(state: CostUsageCodexTokenAccumulatorState? = nil) {
            guard let state else { return }
            self.countedTotals = state.countedTotals
            self.rawTotalsBaseline = state.rawTotalsBaseline
            self.sawDivergentTotals = state.sawDivergentTotals
            self.tracker = CodexTotalsTracker(
                watermark: state.rawTotalsWatermark,
                seenRawTotals: state.seenRawTotals,
                sawInterleavedTotals: state.sawInterleavedTotals)
        }

        var state: CostUsageCodexTokenAccumulatorState {
            CostUsageCodexTokenAccumulatorState(
                countedTotals: self.countedTotals,
                rawTotalsBaseline: self.rawTotalsBaseline,
                sawDivergentTotals: self.sawDivergentTotals,
                rawTotalsWatermark: self.tracker.watermark,
                seenRawTotals: self.tracker.seenRawTotals,
                sawInterleavedTotals: self.tracker.sawInterleavedTotals)
        }

        /// Applies one token-count event and returns the counted cumulative totals afterwards.
        mutating func apply(
            last: CostUsageCodexTotals?,
            total: CostUsageCodexTotals?) -> CostUsageCodexTotals
        {
            let hasReasoning = last?.reasoning != nil || total?.reasoning != nil
            let base = self.countedTotals ?? .init(
                input: 0,
                cached: 0,
                output: 0,
                reasoning: hasReasoning ? 0 : nil)
            if let total {
                // Best-effort exact re-emission suppression (precision only; containment is load-bearing).
                if self.tracker.isSeen(total) {
                    return base
                }
                self.tracker.latchIfBelowWatermark(total)
            }
            let watermarkBaseline = self.tracker.watermark ?? self.rawTotalsBaseline
            defer {
                if let total {
                    self.tracker.commitObserved(total)
                }
            }

            if let last {
                var countedDelta = last
                if let total {
                    if self.tracker.sawInterleavedTotals {
                        countedDelta = CostUsageScanner.codexPostLatchEventDelta(
                            watermark: watermarkBaseline,
                            counted: self.countedTotals,
                            current: total,
                            adjustedLast: last)
                    } else {
                        let totalDelta = CostUsageScanner.codexTotalDelta(from: watermarkBaseline, to: total)
                        if CostUsageScanner.codexShouldPreferTotalDelta(
                            rawBaseline: watermarkBaseline,
                            currentTotal: total,
                            totalDelta: totalDelta,
                            lastDelta: last,
                            sawDivergentTotals: self.sawDivergentTotals)
                        {
                            countedDelta = totalDelta
                        }
                    }
                    let next = CostUsageScanner.codexAddTotals(base, countedDelta)
                    self.countedTotals = next
                    self.rawTotalsBaseline = total
                    if !CostUsageScanner.codexTotalsEqual(total, next) {
                        self.sawDivergentTotals = true
                    }
                    return next
                }
                let next = CostUsageScanner.codexAddTotals(base, countedDelta)
                self.countedTotals = next
                self.rawTotalsBaseline = next
                self.tracker.raiseWatermark(to: next)
                return next
            }

            if let total {
                let delta: CostUsageCodexTotals = if self.tracker.sawInterleavedTotals {
                    CostUsageScanner.codexContainedTotalDelta(
                        watermark: watermarkBaseline,
                        counted: self.countedTotals,
                        current: total)
                } else if self.sawDivergentTotals {
                    CostUsageScanner.codexDivergentTotalDelta(
                        rawBaseline: watermarkBaseline,
                        countedBaseline: self.countedTotals,
                        current: total)
                } else {
                    CostUsageScanner.codexTotalDelta(from: watermarkBaseline, to: total)
                }
                let counted = CostUsageScanner.codexAddTotals(base, delta)
                self.countedTotals = counted
                self.rawTotalsBaseline = total
                if !CostUsageScanner.codexTotalsEqual(total, counted) {
                    self.sawDivergentTotals = true
                }
                return counted
            }

            return base
        }
    }

    static let codexTokenCheckpointStride: Int64 = 4 * 1024 * 1024

    static func codexTokenCheckpoints(
        for events: [CostUsageCodexTokenSnapshot]) -> [CostUsageCodexTokenCheckpoint]
    {
        guard !events.isEmpty else { return [] }
        var accumulator = CodexSnapshotAccumulator()
        var checkpoints: [CostUsageCodexTokenCheckpoint] = []
        var lastCheckpointOffset: Int64 = 0

        for (eventIndex, event) in events.enumerated() {
            _ = accumulator.apply(last: event.last, total: event.total)
            guard let endOffset = event.endOffset else { continue }
            let reachedStride = endOffset - lastCheckpointOffset >= Self.codexTokenCheckpointStride
            let isLastEvent = eventIndex == events.index(before: events.endIndex)
            guard reachedStride || isLastEvent else { continue }
            checkpoints.append(CostUsageCodexTokenCheckpoint(
                eventIndex: eventIndex,
                timestamp: event.timestamp,
                endOffset: endOffset,
                state: accumulator.state))
            lastCheckpointOffset = endOffset
        }

        return checkpoints
    }

    static func codexTokenTimestampsAreMonotonic(
        _ events: [CostUsageCodexTokenSnapshot]) -> Bool
    {
        guard events.count > 1 else { return true }
        for (previous, current) in zip(events, events.dropFirst())
            where !self.codexTokenTimestampIsOrdered(previous.timestamp, current.timestamp)
        {
            return false
        }
        return true
    }

    private static func codexTokenTimestampIsOrdered(_ previous: String, _ current: String) -> Bool {
        if let previousDate = dateFromTimestamp(previous),
           let currentDate = dateFromTimestamp(current)
        {
            return previousDate <= currentDate
        }
        return previous <= current
    }

    struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
        let tokenIndexStore: CostUsageCodexTokenIndexStore
        let usageRowStore: CostUsageCodexUsageRowStore
        let projectPathResolver: CodexCanonicalProjectPathResolver
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let priorityTurns: [String: CodexPriorityTurnMetadata]
        let publishedProducerKey: String
        let currentProducerKey: String
        let pricingKey: String
        let priorityMetadataKey: String
        let timeZoneIdentifier: String
    }

    struct CodexFileScanContext {
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let dropDeferredCodexRows: Bool
        let requiresTurnIDCache: Bool
        let changedPriorityTurnIDs: Set<String>
        let resources: CodexScanResources
        let checkCancellation: CancellationCheck?
        let scanBudget: CodexScanBudget?
    }

    struct CodexBufferedForkDependencyPreparation {
        let cutoffTimestamp: String
        let isReady: Bool
        let stableDependencyKey: String?
    }

    /// Checks whether a completed buffered fork can be replayed before touching the buffer's token
    /// events. Legacy caches locate the authoritative metadata once; the recovered cutoff is then
    /// persisted so subsequent refreshes remain constant-work while their parent is still scanning.
    static func prepareBufferedForkDependency(
        usage: CostUsageFileUsage,
        inheritedResolver: CodexInheritedTotalsResolver) throws -> CodexBufferedForkDependencyPreparation?
    {
        guard usage.hasBufferedCodexForkRetryLines || usage.codexDeferredForkScan == true,
              usage.forkBaselineDependencyKey != self.codexForkDependencyNotRequiredKey,
              let parentSessionId = usage.forkedFromId
        else { return nil }

        let cutoffTimestamp = usage.codexForkTimestamp ?? Self.bufferedCodexForkTimestamp(usage)
        guard let cutoffTimestamp, !cutoffTimestamp.isEmpty else { return nil }
        return try Self.prepareCodexForkDependency(
            parentSessionId: parentSessionId,
            cutoffTimestamp: cutoffTimestamp,
            inheritedResolver: inheritedResolver)
    }

    private static func prepareCodexForkDependency(
        parentSessionId: String,
        cutoffTimestamp: String,
        inheritedResolver: CodexInheritedTotalsResolver) throws -> CodexBufferedForkDependencyPreparation
    {
        switch try inheritedResolver.inheritedTotals(
            for: parentSessionId,
            atOrBefore: cutoffTimestamp)
        {
        case .resolved:
            CodexBufferedForkDependencyPreparation(
                cutoffTimestamp: cutoffTimestamp,
                isReady: true,
                stableDependencyKey: inheritedResolver.dependencyKeyUsed(for: parentSessionId))
        case .unresolved:
            CodexBufferedForkDependencyPreparation(
                cutoffTimestamp: cutoffTimestamp,
                isReady: false,
                stableDependencyKey: inheritedResolver.dependencyKeyUsed(for: parentSessionId))
        }
    }

    /// Only ordinary forks with explicit authoritative metadata are eligible for the tiny deferred
    /// marker. Subagent buffers retain their full shape because later lineage can affect attribution.
    private static func bufferedOrdinaryCodexForkMetadata(
        _ usage: CostUsageFileUsage) -> CodexSessionMetadata?
    {
        guard usage.codexBufferedSubagentLines?.isEmpty != false else { return nil }
        for buffered in usage.codexBufferedUnresolvedForkLines ?? [] {
            guard case let .sessionMeta(metadata) = buffered.line,
                  !metadata.isSubagentThread,
                  metadata.sessionId == usage.sessionId,
                  metadata.forkedFromId == usage.forkedFromId,
                  metadata.forkTimestamp?.isEmpty == false
            else { continue }
            return metadata
        }
        return nil
    }

    private static func bufferedCodexForkTimestamp(_ usage: CostUsageFileUsage) -> String? {
        let buffers = usage.codexBufferedUnresolvedForkLines ?? usage.codexBufferedSubagentLines ?? []
        for buffered in buffers {
            guard case let .sessionMeta(metadata) = buffered.line,
                  metadata.sessionId == usage.sessionId,
                  metadata.forkedFromId == usage.forkedFromId,
                  let forkTimestamp = metadata.forkTimestamp,
                  !forkTimestamp.isEmpty
            else { continue }
            return forkTimestamp
        }
        return nil
    }

    final class CodexCanonicalProjectPathResolver {
        private var cache: [String: String] = [:]
        private let homeCodexWorktreesPrefix: String

        init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
            // Provider-specific by design: Codex worktree sessions canonicalize to their source project path.
            self.homeCodexWorktreesPrefix = homeDirectory
                .appendingPathComponent(".codex/worktrees", isDirectory: true)
                .standardizedFileURL
                .path
        }

        func canonicalProjectPath(for projectPath: String?) -> String? {
            guard let projectPath else { return nil }
            if let cached = self.cache[projectPath] {
                return cached
            }
            let resolved = self.resolveCanonicalProjectPath(projectPath) ?? projectPath
            self.cache[projectPath] = resolved
            return resolved
        }

        private func resolveCanonicalProjectPath(_ projectPath: String) -> String? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            guard let output = self.gitWorktreeList(projectPath: projectPath) else { return nil }
            let worktrees = output
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard line.hasPrefix("worktree ") else { return nil }
                    let rawPath = line.dropFirst("worktree ".count)
                    return Self.standardizedAbsolutePath(String(rawPath))
                }
            guard !worktrees.isEmpty else { return nil }
            return worktrees.first { !self.isEphemeralWorktreePath($0) }
        }

        private func gitWorktreeList(projectPath: String) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", projectPath, "worktree", "list", "--porcelain"]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let outputCapture = ProcessPipeCapture(pipe: outputPipe)
            let errorCapture = ProcessPipeCapture(pipe: errorPipe)

            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            do {
                try process.run()
            } catch {
                return nil
            }
            outputCapture.start()
            errorCapture.start()

            if semaphore.wait(timeout: .now() + .seconds(1)) == .timedOut {
                process.terminate()
                outputCapture.stop()
                errorCapture.stop()
                return nil
            }
            let data = outputCapture.finishSynchronously(timeout: 0.1)
            errorCapture.stop()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private func isEphemeralWorktreePath(_ path: String) -> Bool {
            path == self.homeCodexWorktreesPrefix
                || path.hasPrefix(self.homeCodexWorktreesPrefix + "/")
                || path.hasSuffix("/.codex/worktrees")
                || path.contains("/.codex/worktrees/")
                || path == "/private/tmp"
                || path.hasPrefix("/private/tmp/")
        }

        private static func standardizedAbsolutePath(_ path: String) -> String? {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        }
    }

    struct CodexRefreshPlan {
        let refreshMs: Int64
        let roots: [URL]
        let rootsFingerprint: [String: Int64]
        let rootsChanged: Bool
        let windowExpanded: Bool
        let needsCostCacheMigration: Bool
        let needsProjectMetadataMigration: Bool
        let modelsDevCatalog: ModelsDevCatalog?
        let codexPricingKey: String
        let codexPriorityMetadataKey: String
        let hasPriorityMetadata: Bool
        let priorityTurns: [String: CodexPriorityTurnMetadata]
        let priorityTurnKeys: [String: String]
        let priorityTurnIDsByDay: [String: [String]]
        let pricingChanged: Bool
        let priorityMetadataChanged: Bool
        let priorityTurnsChanged: Bool
        let needsTurnIDCacheMigration: Bool
        let changedPriorityTurnIDs: Set<String>
        let shouldRefresh: Bool
    }

    final class CodexSessionFileIndex {
        enum Lookup {
            case found(URL)
            case missing(dependencyKey: String)
            case deferred
        }

        private enum InventoryValidation {
            case current
            case changed
            case deferred
        }

        private let files: [URL]
        private let roots: [URL]
        private let checkCancellation: CancellationCheck?
        private let scanBudget: CodexScanBudget?
        private let headParseObserver: (() -> Void)?
        private var discovery: CostUsageCodexSessionDiscovery
        private var inventoryValidatedThisRefresh = false

        init(
            files: [URL],
            roots: [URL],
            cachedSessionFiles: [String: URL] = [:],
            cachedDiscovery: CostUsageCodexSessionDiscovery? = nil,
            scanBudget: CodexScanBudget? = nil,
            headParseObserver: (() -> Void)? = nil,
            checkCancellation: CancellationCheck? = nil)
        {
            self.files = files
            self.roots = roots
            self.checkCancellation = checkCancellation
            self.scanBudget = scanBudget
            self.headParseObserver = headParseObserver
            let rootPaths = roots.map(\.standardizedFileURL.path).sorted()
            if var cachedDiscovery, cachedDiscovery.roots == rootPaths {
                for (sessionId, fileURL) in cachedSessionFiles {
                    cachedDiscovery.filePathBySessionId[sessionId] = fileURL.standardizedFileURL.path
                }
                self.discovery = cachedDiscovery
                if !cachedDiscovery.isComplete {
                    self.enqueueCurrentFiles()
                }
            } else {
                self.discovery = Self.makeFreshDiscovery(
                    roots: roots,
                    files: files,
                    cachedSessionFiles: cachedSessionFiles,
                    retaining: nil)
            }
        }

        var persistedState: CostUsageCodexSessionDiscovery {
            self.discovery
        }

        var hasPendingDiscovery: Bool {
            !self.discovery.isComplete
                && (!self.discovery.pendingSessionIds.isEmpty || self.discovery.headScan != nil)
        }

        func remember(fileURL: URL, sessionId: String?) {
            guard let sessionId, !sessionId.isEmpty else { return }
            let path = fileURL.standardizedFileURL.path
            self.discovery.filePathBySessionId = self.discovery.filePathBySessionId.filter {
                $0.key == sessionId || $0.value != path
            }
            self.discovery.filePathBySessionId[sessionId] = path
            self.discovery.missingSessionIds.removeAll { $0 == sessionId }
            self.discovery.pendingSessionIds.removeAll { $0 == sessionId }
            self.discovery.fileStamps[path] = Self.fileStamp(fileURL: fileURL)
        }

        func lookup(sessionId: String) throws -> Lookup {
            if let cached = self.cachedFileURL(for: sessionId) {
                return .found(cached)
            }

            if self.discovery.isComplete {
                if self.inventoryValidatedThisRefresh {
                    return self.recordMissingLookup(sessionId: sessionId)
                }
                switch try self.validateInventory() {
                case .current:
                    self.inventoryValidatedThisRefresh = true
                    return self.recordMissingLookup(sessionId: sessionId)
                case .changed:
                    self.inventoryValidatedThisRefresh = false
                    let knownFiles = (self.files + self.discovery.filePaths.map {
                        URL(fileURLWithPath: $0)
                    }).filter { FileManager.default.fileExists(atPath: $0.path) }
                    self.discovery = Self.makeFreshDiscovery(
                        roots: self.roots,
                        files: knownFiles,
                        cachedSessionFiles: self.cachedSessionFiles(),
                        retaining: self.discovery)
                case .deferred:
                    return .deferred
                }
            }

            if !self.discovery.pendingSessionIds.contains(sessionId) {
                self.discovery.pendingSessionIds.append(sessionId)
            }
            return try self.resumeDiscovery(requestedSessionId: sessionId)
        }

        private func cachedFileURL(for sessionId: String) -> URL? {
            guard let path = self.discovery.filePathBySessionId[sessionId] else { return nil }
            guard FileManager.default.fileExists(atPath: path) else {
                self.invalidateDiscoveredFile(path: path)
                return nil
            }
            let fileURL = URL(fileURLWithPath: path)
            guard self.discovery.fileStamps[path] == Self.fileStamp(fileURL: fileURL) else {
                self.invalidateDiscoveredFile(path: path)
                return nil
            }
            return fileURL
        }

        private func invalidateDiscoveredFile(path: String) {
            self.discovery.filePathBySessionId = self.discovery.filePathBySessionId.filter {
                $0.value != path
            }
            self.discovery.fileStamps.removeValue(forKey: path)
            self.discovery.missingSessionIds.removeAll()
            self.discovery.generation = nil
            self.discovery.isComplete = false
            self.discovery.validationDirectoryIndex = 0
            self.discovery.validationFileIndex = nil
            if let index = self.discovery.filePaths.firstIndex(of: path) {
                self.discovery.filePaths.remove(at: index)
                if index < self.discovery.nextFileIndex {
                    self.discovery.nextFileIndex -= 1
                }
            }
            self.discovery.filePaths.append(path)
            if self.discovery.headScan?.path == path {
                self.discovery.headScan = nil
            }
        }

        private func cachedSessionFiles() -> [String: URL] {
            self.discovery.filePathBySessionId.reduce(into: [:]) { result, entry in
                guard FileManager.default.fileExists(atPath: entry.value) else { return }
                let fileURL = URL(fileURLWithPath: entry.value)
                guard self.discovery.fileStamps[entry.value] == Self.fileStamp(fileURL: fileURL)
                else { return }
                result[entry.key] = fileURL
            }
        }

        private func resumeDiscovery(requestedSessionId: String) throws -> Lookup {
            while true {
                try self.checkCancellation?()
                if let cached = self.cachedFileURL(for: requestedSessionId) {
                    return .found(cached)
                }

                if self.discovery.nextFileIndex < self.discovery.filePaths.count {
                    guard try self.scanNextFileHead() else { return .deferred }
                    continue
                }

                if self.discovery.nextDirectoryIndex < self.discovery.directoryPaths.count {
                    guard try self.enumerateNextDirectory() else { return .deferred }
                    continue
                }

                self.finishDiscovery()
                if let cached = self.cachedFileURL(for: requestedSessionId) {
                    return .found(cached)
                }
                return self.recordMissingLookup(sessionId: requestedSessionId)
            }
        }

        private func recordMissingLookup(sessionId: String) -> Lookup {
            if !self.discovery.missingSessionIds.contains(sessionId) {
                self.discovery.missingSessionIds.append(sessionId)
                self.discovery.missingSessionIds.sort()
            }
            self.discovery.pendingSessionIds.removeAll { $0 == sessionId }
            let generation = self.discovery.generation ?? "unknown"
            return .missing(dependencyKey: Self.missingDependencyKey(
                sessionId: sessionId,
                generation: generation))
        }

        private func scanNextFileHead() throws -> Bool {
            let path = self.discovery.filePaths[self.discovery.nextFileIndex]
            let fileURL = URL(fileURLWithPath: path)
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            guard metadata.fileId != nil else {
                self.advancePastHead(path: path, stamp: nil)
                return true
            }

            let currentStamp = Self.fileStamp(metadata: metadata)
            if self.discovery.fileStamps[path] == currentStamp {
                // `remember(fileURL:sessionId:)` may already have learned this authoritative
                // identity from the scanner's metadata preflight. Do not spend the byte budget
                // parsing the same head again while looking for a different parent session.
                self.advancePastHead(path: path, stamp: currentStamp)
                return true
            }

            var head = self.discovery.headScan
            if head?.path != path || head?.sourceStamp != currentStamp {
                head = CostUsageCodexSessionDiscovery.HeadScan(
                    path: path,
                    offset: 0,
                    resumeState: nil,
                    sourceStamp: currentStamp)
            }
            let startOffset = head?.resumeState?.offset ?? head?.offset ?? 0
            let remainingBytes = max(0, metadata.size - startOffset)
            let admittedBytes: Int64
            if let scanBudget = self.scanBudget {
                switch scanBudget.admit(workBytes: remainingBytes) {
                case let .allow(allowance): admittedBytes = allowance
                case .deferBudget: return false
                }
            } else {
                admittedBytes = remainingBytes
            }

            self.headParseObserver?()
            let result = try CostUsageScanner.scanCodexSessionIdentifier(
                fileURL: fileURL,
                offset: head?.offset ?? 0,
                maxBytesToRead: admittedBytes,
                resumeState: head?.resumeState,
                checkCancellation: self.checkCancellation)
            self.scanBudget?.complete(
                admittedWorkBytes: admittedBytes,
                actualWorkBytes: result.bytesRead)

            let metadataAfterRead = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            let stampAfterRead = Self.fileStamp(metadata: metadataAfterRead)
            guard stampAfterRead == currentStamp else {
                // Never combine a resumable prefix from one inode/version with bytes from the
                // next. Restart discovery from zero against the new stamp on a later refresh.
                self.scanBudget?.recordSourceMutationDeferral()
                self.discovery.headScan = CostUsageCodexSessionDiscovery.HeadScan(
                    path: path,
                    offset: 0,
                    resumeState: nil,
                    sourceStamp: stampAfterRead)
                return false
            }

            if let sessionId = result.sessionId, !sessionId.isEmpty {
                self.discovery.filePathBySessionId[sessionId] = path
                self.advancePastHead(path: path, stamp: currentStamp)
                return true
            }
            if result.isComplete {
                self.advancePastHead(path: path, stamp: currentStamp)
                return true
            }

            self.discovery.headScan = CostUsageCodexSessionDiscovery.HeadScan(
                path: path,
                offset: result.committedOffset,
                resumeState: result.resumeState,
                sourceStamp: currentStamp)
            return false
        }

        private func advancePastHead(
            path: String,
            stamp: CostUsageCodexSessionDiscovery.FileStamp?)
        {
            if let stamp {
                self.discovery.fileStamps[path] = stamp
            } else {
                self.discovery.fileStamps.removeValue(forKey: path)
                self.discovery.filePathBySessionId = self.discovery.filePathBySessionId.filter { $0.value != path }
            }
            self.discovery.headScan = nil
            self.discovery.nextFileIndex += 1
        }

        private func enumerateNextDirectory() throws -> Bool {
            let admittedWork: Int64
            if let scanBudget = self.scanBudget {
                switch scanBudget.admit(workBytes: 1) {
                case let .allow(allowance): admittedWork = allowance
                case .deferBudget: return false
                }
            } else {
                admittedWork = 1
            }
            defer {
                self.scanBudget?.complete(admittedWorkBytes: admittedWork, actualWorkBytes: admittedWork)
            }

            try self.checkCancellation?()
            let path = self.discovery.directoryPaths[self.discovery.nextDirectoryIndex]
            let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            let items = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            var jsonlFileCount = 0
            for item in items {
                try self.checkCancellation?()
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    self.enqueueDirectory(item)
                } else if item.pathExtension.lowercased() == "jsonl" {
                    jsonlFileCount += 1
                    self.enqueueFile(item)
                }
            }
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: directoryURL)
            self.discovery.directoryStamps[path] = .init(
                mtimeUnixMs: metadata.mtimeUnixMs,
                jsonlFileCount: jsonlFileCount)
            self.discovery.nextDirectoryIndex += 1
            return !self.scanBudgetExhausted()
        }

        private func enqueueCurrentFiles() {
            for fileURL in self.files {
                self.enqueueFile(fileURL)
            }
        }

        private func enqueueFile(_ fileURL: URL) {
            let path = fileURL.standardizedFileURL.path
            guard !self.discovery.filePaths.contains(path) else { return }
            self.discovery.filePaths.append(path)
        }

        private func enqueueDirectory(_ directoryURL: URL) {
            let path = directoryURL.standardizedFileURL.path
            guard !self.discovery.directoryPaths.contains(path) else { return }
            self.discovery.directoryPaths.append(path)
        }

        private func finishDiscovery() {
            let generation = Self.discoveryGeneration(
                roots: self.discovery.roots,
                directoryStamps: self.discovery.directoryStamps)
            self.discovery.generation = generation
            for sessionId in self.discovery.pendingSessionIds
                where self.discovery.filePathBySessionId[sessionId] == nil
            {
                if !self.discovery.missingSessionIds.contains(sessionId) {
                    self.discovery.missingSessionIds.append(sessionId)
                }
            }
            self.discovery.missingSessionIds.sort()
            self.discovery.pendingSessionIds.removeAll()
            self.discovery.directoryPaths = self.discovery.directoryStamps.keys.sorted()
            self.discovery.nextDirectoryIndex = self.discovery.directoryPaths.count
            self.discovery.validationDirectoryIndex = 0
            self.discovery.validationFileIndex = nil
            self.discovery.isComplete = true
            self.inventoryValidatedThisRefresh = true
        }

        private func validateInventory() throws -> InventoryValidation {
            // Directory mtimes do not change when an existing JSONL is rewritten in place.
            // Validate mapped and unmapped files alike so a session A -> B replacement cannot
            // leave A resolvable forever or record B as a stable missing parent.
            let stampedPaths = self.discovery.fileStamps.keys.sorted()
            var validationFileIndex = self.discovery.validationFileIndex ?? 0
            while validationFileIndex < stampedPaths.count {
                let admittedWork: Int64
                if let scanBudget = self.scanBudget {
                    switch scanBudget.admit(workBytes: 1) {
                    case let .allow(allowance): admittedWork = allowance
                    case .deferBudget:
                        self.discovery.validationFileIndex = validationFileIndex
                        return .deferred
                    }
                } else {
                    admittedWork = 1
                }

                try self.checkCancellation?()
                let path = stampedPaths[validationFileIndex]
                let current = Self.fileStamp(fileURL: URL(fileURLWithPath: path))
                self.scanBudget?.complete(admittedWorkBytes: admittedWork, actualWorkBytes: admittedWork)
                guard current == self.discovery.fileStamps[path] else {
                    self.discovery.validationFileIndex = nil
                    self.discovery.validationDirectoryIndex = 0
                    return .changed
                }
                validationFileIndex += 1
                self.discovery.validationFileIndex = validationFileIndex
                if self.scanBudgetExhausted() {
                    return .deferred
                }
            }
            self.discovery.validationFileIndex = nil

            while self.discovery.validationDirectoryIndex < self.discovery.directoryPaths.count {
                let admittedWork: Int64
                if let scanBudget = self.scanBudget {
                    switch scanBudget.admit(workBytes: 1) {
                    case let .allow(allowance): admittedWork = allowance
                    case .deferBudget: return .deferred
                    }
                } else {
                    admittedWork = 1
                }

                try self.checkCancellation?()
                let path = self.discovery.directoryPaths[self.discovery.validationDirectoryIndex]
                let currentMtime = Self.directoryModificationTime(atPath: path)
                self.scanBudget?.complete(admittedWorkBytes: admittedWork, actualWorkBytes: admittedWork)
                guard currentMtime == self.discovery.directoryStamps[path]?.mtimeUnixMs else {
                    self.discovery.validationDirectoryIndex = 0
                    return .changed
                }
                self.discovery.validationDirectoryIndex += 1
                if self.scanBudgetExhausted() {
                    return .deferred
                }
            }
            self.discovery.validationDirectoryIndex = 0
            return .current
        }

        private func scanBudgetExhausted() -> Bool {
            guard let scanBudget = self.scanBudget else { return false }
            switch scanBudget.admit(workBytes: 1) {
            case let .allow(allowance):
                scanBudget.release(workBytes: allowance)
                return false
            case .deferBudget:
                return true
            }
        }

        private static func makeFreshDiscovery(
            roots: [URL],
            files: [URL],
            cachedSessionFiles: [String: URL],
            retaining previous: CostUsageCodexSessionDiscovery?) -> CostUsageCodexSessionDiscovery
        {
            let rootPaths = roots.map(\.standardizedFileURL.path).sorted()
            var retainedStamps: [String: CostUsageCodexSessionDiscovery.FileStamp] = [:]
            if let previous {
                for (path, stamp) in previous.fileStamps {
                    let current = Self.fileStamp(fileURL: URL(fileURLWithPath: path))
                    if current == stamp {
                        retainedStamps[path] = stamp
                    }
                }
            }
            for fileURL in cachedSessionFiles.values {
                let path = fileURL.standardizedFileURL.path
                if let stamp = Self.fileStamp(fileURL: fileURL) {
                    retainedStamps[path] = stamp
                }
            }

            let retainedPaths = retainedStamps.keys.sorted()
            var sessionFiles = previous?.filePathBySessionId.filter {
                retainedStamps[$0.value] != nil
            } ?? [:]
            for (sessionId, fileURL) in cachedSessionFiles {
                sessionFiles[sessionId] = fileURL.standardizedFileURL.path
            }
            var filePaths = retainedPaths
            var knownPaths = Set(filePaths)
            for fileURL in files {
                let path = fileURL.standardizedFileURL.path
                if knownPaths.insert(path).inserted {
                    filePaths.append(path)
                }
            }
            return CostUsageCodexSessionDiscovery(
                roots: rootPaths,
                generation: nil,
                directoryStamps: [:],
                directoryPaths: rootPaths,
                nextDirectoryIndex: 0,
                filePaths: filePaths,
                nextFileIndex: retainedPaths.count,
                fileStamps: retainedStamps,
                headScan: nil,
                filePathBySessionId: sessionFiles,
                missingSessionIds: [],
                pendingSessionIds: [],
                validationDirectoryIndex: 0,
                isComplete: false)
        }

        private static func directoryModificationTime(atPath path: String) -> Int64? {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
            guard metadata.fileId != nil else { return nil }
            return metadata.mtimeUnixMs
        }

        private static func fileStamp(
            fileURL: URL) -> CostUsageCodexSessionDiscovery.FileStamp?
        {
            self.fileStamp(metadata: CostUsageScanner.codexFileMetadata(fileURL: fileURL))
        }

        private static func fileStamp(
            metadata: CodexFileMetadata) -> CostUsageCodexSessionDiscovery.FileStamp?
        {
            guard metadata.fileId != nil else { return nil }
            return .init(
                mtimeUnixMs: metadata.mtimeUnixMs,
                size: metadata.size,
                fileId: metadata.fileId,
                changeUnixNs: metadata.changeUnixNs)
        }

        private static func discoveryGeneration(
            roots: [String],
            directoryStamps: [String: CostUsageCodexSessionDiscovery.DirectoryStamp]) -> String
        {
            let directories = directoryStamps.map { path, stamp in
                "\(path)|\(stamp.mtimeUnixMs)|\(stamp.jsonlFileCount)"
            }.sorted()
            return CostUsageScanner.sha256Hex(Data((roots + directories).joined(separator: "\n").utf8))
        }

        private static func missingDependencyKey(sessionId: String, generation: String) -> String {
            "missing|\(sessionId)|discovery|\(generation)"
        }
    }

    private struct CodexSessionIdentifierScanResult {
        let sessionId: String?
        let bytesRead: Int64
        let committedOffset: Int64
        let resumeState: CostUsageJsonl.ResumeState?
        let isComplete: Bool
    }

    private static func scanCodexSessionIdentifier(
        fileURL: URL,
        offset: Int64,
        maxBytesToRead: Int64,
        resumeState: CostUsageJsonl.ResumeState?,
        checkCancellation: CancellationCheck?) throws -> CodexSessionIdentifierScanResult
    {
        var sessionId: String?
        let scanStart = resumeState?.offset ?? max(0, offset)
        let progress = try CostUsageJsonl.scanBounded(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: Self.codexSessionMetadataMaxLineBytes,
            prefixBytes: Self.codexSessionMetadataMaxLineBytes,
            maxBytesToRead: maxBytesToRead,
            resumeState: resumeState,
            shouldStop: { _ in sessionId != nil },
            checkCancellation: checkCancellation,
            onLine: { line in
                guard !line.wasTruncated else { return }
                if case let .sessionMeta(metadata) = Self.parseCodexFastLine(line.bytes) {
                    sessionId = metadata.sessionId
                }
            })
        let size = Self.codexFileMetadata(fileURL: fileURL).size
        return CodexSessionIdentifierScanResult(
            sessionId: sessionId,
            bytesRead: max(0, progress.readOffset - scanStart),
            committedOffset: progress.committedOffset,
            resumeState: progress.resumeState,
            isComplete: sessionId != nil || progress.readOffset >= size)
    }

    final class CodexInheritedTotalsResolver {
        private struct SnapshotResolution {
            let dependencyKey: String?
            let snapshots: [CodexTimestampedTotals]?
            let indexedEvents: [CostUsageCodexTokenSnapshot]?
            let sidecarReference: CostUsageCodexTokenIndexReference?
            let checkpoints: [CostUsageCodexTokenCheckpoint]
            let indexedTimestampsMonotonic: Bool
            let isComplete: Bool
            let unresolvedDependencyIsStable: Bool
            let sourceURL: URL?

            init(
                dependencyKey: String?,
                snapshots: [CodexTimestampedTotals]? = nil,
                indexedEvents: [CostUsageCodexTokenSnapshot]? = nil,
                sidecarReference: CostUsageCodexTokenIndexReference? = nil,
                checkpoints: [CostUsageCodexTokenCheckpoint] = [],
                indexedTimestampsMonotonic: Bool = false,
                isComplete: Bool,
                unresolvedDependencyIsStable: Bool = false,
                sourceURL: URL? = nil)
            {
                self.dependencyKey = dependencyKey
                self.snapshots = snapshots
                self.indexedEvents = indexedEvents
                self.sidecarReference = sidecarReference
                self.checkpoints = checkpoints
                self.indexedTimestampsMonotonic = indexedTimestampsMonotonic
                self.isComplete = isComplete
                self.unresolvedDependencyIsStable = unresolvedDependencyIsStable
                self.sourceURL = sourceURL
            }

            var hasSnapshotSource: Bool {
                self.sidecarReference != nil || self.indexedEvents != nil || self.snapshots != nil
            }
        }

        private let fileIndex: CodexSessionFileIndex
        private let checkCancellation: CancellationCheck?
        private let scanBudget: CodexScanBudget?
        private let tokenIndexStore: CostUsageCodexTokenIndexStore
        private var cachedFiles: [String: CostUsageFileUsage]
        private var cachedFilesByFileID: [String: [String: CostUsageFileUsage]]
        private var snapshotResolutions: [String: SnapshotResolution] = [:]
        private var resolvedDependencyKeys: [String: String] = [:]
        private var pendingParentFiles: [String: URL] = [:]
        private var tokenIndexRebuildPaths: Set<String> = []

        init(
            fileIndex: CodexSessionFileIndex,
            checkCancellation: CancellationCheck?,
            scanBudget: CodexScanBudget? = nil,
            tokenIndexStore: CostUsageCodexTokenIndexStore = .init(),
            cachedFiles: [String: CostUsageFileUsage] = [:])
        {
            self.fileIndex = fileIndex
            self.checkCancellation = checkCancellation
            self.scanBudget = scanBudget
            self.tokenIndexStore = tokenIndexStore
            self.cachedFiles = cachedFiles
            self.cachedFilesByFileID = cachedFiles.reduce(into: [:]) { index, entry in
                guard let fileID = entry.value.codexScanFileId else { return }
                index[fileID, default: [:]][entry.key] = entry.value
            }
        }

        func updateCachedUsage(fileURL: URL, usage: CostUsageFileUsage?) {
            let path = fileURL.path
            let standardizedPath = fileURL.standardizedFileURL.path
            let paths = Set([path, standardizedPath])
            var affectedSessionIDs = Set([usage?.sessionId].compactMap(\.self))
            for cachedPath in paths {
                guard let previous = self.cachedFiles.removeValue(forKey: cachedPath) else { continue }
                if let previousSessionID = previous.sessionId {
                    affectedSessionIDs.insert(previousSessionID)
                }
                if let previousFileID = previous.codexScanFileId,
                   var aliases = self.cachedFilesByFileID[previousFileID]
                {
                    aliases.removeValue(forKey: cachedPath)
                    if aliases.isEmpty {
                        self.cachedFilesByFileID.removeValue(forKey: previousFileID)
                    } else {
                        self.cachedFilesByFileID[previousFileID] = aliases
                    }
                }
            }
            if let usage {
                for cachedPath in paths {
                    self.cachedFiles[cachedPath] = usage
                    if let fileID = usage.codexScanFileId {
                        self.cachedFilesByFileID[fileID, default: [:]][cachedPath] = usage
                    }
                }
            }
            for sessionId in affectedSessionIDs {
                self.snapshotResolutions.removeValue(forKey: sessionId)
                self.resolvedDependencyKeys.removeValue(forKey: sessionId)
            }
        }

        func requiresTokenIndexRebuild(fileURL: URL) -> Bool {
            self.tokenIndexRebuildPaths.contains(
                CostUsageCodexTokenIndexStore.sourcePath(for: fileURL))
        }

        func inheritedTotals(for sessionId: String, atOrBefore cutoffTimestamp: String) throws -> CodexForkBaseline {
            // This side channel describes the current cutoff lookup, not any earlier child that
            // happened to share the parent session.
            self.resolvedDependencyKeys.removeValue(forKey: sessionId)
            guard !cutoffTimestamp.isEmpty else {
                CostUsageScanner.log.warning(
                    "Codex cost usage fork timestamp missing; treating parent baseline as unresolved",
                    metadata: ["sessionId": sessionId])
                return .unresolved
            }
            let cutoffDate = CostUsageScanner.dateFromTimestamp(cutoffTimestamp)
            if cutoffDate == nil {
                CostUsageScanner.log.warning(
                    "Codex cost usage could not parse fork timestamp; falling back to lexical comparison",
                    metadata: ["sessionId": sessionId, "timestamp": cutoffTimestamp])
            }
            let resolution = try self.snapshotResolution(for: sessionId)
            guard resolution.hasSnapshotSource else {
                if resolution.unresolvedDependencyIsStable, let dependencyKey = resolution.dependencyKey {
                    self.resolvedDependencyKeys[sessionId] = dependencyKey
                }
                return .unresolved
            }
            // Legacy rollout timestamps come from wall clock and are not a proven monotonic file
            // boundary. An unread suffix can still contain another event at or before the cutoff,
            // so only an EOF-complete parent is safe to publish as an inherited baseline.
            guard resolution.isComplete else { return .unresolved }
            if let reference = resolution.sidecarReference {
                switch self.tokenIndexStore.inheritedTotals(
                    reference: reference,
                    cutoffTimestamp: cutoffTimestamp,
                    cutoffUnixSeconds: cutoffDate?.timeIntervalSince1970)
                {
                case let .ready(inherited):
                    if let dependencyKey = resolution.dependencyKey {
                        self.resolvedDependencyKeys[sessionId] = dependencyKey
                    }
                    return .resolved(inherited)
                case .needsRebuild:
                    if let fileURL = resolution.sourceURL {
                        let path = CostUsageCodexTokenIndexStore.sourcePath(for: fileURL)
                        self.tokenIndexRebuildPaths.insert(path)
                        self.pendingParentFiles[path] = fileURL
                    }
                    return .unresolved
                case .temporarilyUnavailable:
                    return .unresolved
                }
            }
            let inherited = self.inheritedTotals(
                from: resolution,
                cutoffTimestamp: cutoffTimestamp,
                cutoffDate: cutoffDate)
            if let dependencyKey = resolution.dependencyKey {
                self.resolvedDependencyKeys[sessionId] = dependencyKey
            }
            return .resolved(inherited)
        }

        private func inheritedTotals(
            from resolution: SnapshotResolution,
            cutoffTimestamp: String,
            cutoffDate: Date?) -> CostUsageCodexTotals?
        {
            func isAtOrBefore(_ timestamp: String, date: Date? = nil) -> Bool {
                if let date = date ?? CostUsageScanner.dateFromTimestamp(timestamp), let cutoffDate {
                    return date <= cutoffDate
                }
                return timestamp <= cutoffTimestamp
            }

            if let events = resolution.indexedEvents {
                var selectedCheckpoint: CostUsageCodexTokenCheckpoint?
                let checkpointsAreSearchable = resolution.checkpoints.enumerated().allSatisfy { index, checkpoint in
                    checkpoint.eventIndex >= 0
                        && checkpoint.eventIndex < events.count
                        && checkpoint.timestamp == events[checkpoint.eventIndex].timestamp
                        && (index == 0
                            || resolution.checkpoints[index - 1].eventIndex < checkpoint.eventIndex)
                }
                let checkpoints = checkpointsAreSearchable ? resolution.checkpoints : []
                if resolution.indexedTimestampsMonotonic {
                    var lowerBound = 0
                    var upperBound = checkpoints.count
                    while lowerBound < upperBound {
                        let middle = lowerBound + (upperBound - lowerBound) / 2
                        if isAtOrBefore(checkpoints[middle].timestamp) {
                            lowerBound = middle + 1
                        } else {
                            upperBound = middle
                        }
                    }
                    if lowerBound > 0 {
                        selectedCheckpoint = checkpoints[lowerBound - 1]
                    }
                } else {
                    for checkpoint in checkpoints where isAtOrBefore(checkpoint.timestamp) {
                        selectedCheckpoint = checkpoint
                    }
                }

                var accumulator = CodexSnapshotAccumulator(state: selectedCheckpoint?.state)
                var inherited = selectedCheckpoint?.state.countedTotals
                let startIndex = min(events.count, (selectedCheckpoint?.eventIndex ?? -1) + 1)
                for event in events[startIndex...] {
                    let eventIsAtOrBefore = isAtOrBefore(event.timestamp)
                    if resolution.indexedTimestampsMonotonic, !eventIsAtOrBefore {
                        break
                    }
                    let counted = accumulator.apply(last: event.last, total: event.total)
                    if eventIsAtOrBefore {
                        inherited = counted
                    }
                }
                return inherited
            }

            var inherited: CostUsageCodexTotals?
            for snapshot in resolution.snapshots ?? [] where isAtOrBefore(snapshot.timestamp, date: snapshot.date) {
                inherited = snapshot.totals
            }
            return inherited
        }

        func currentDependencyKey(for sessionId: String) throws -> String? {
            switch try self.fileIndex.lookup(sessionId: sessionId) {
            case let .found(fileURL):
                self.dependencyKey(for: sessionId, fileURL: fileURL)
            case let .missing(dependencyKey):
                dependencyKey
            case .deferred:
                nil
            }
        }

        func dependencyKeyUsed(for sessionId: String) -> String? {
            self.resolvedDependencyKeys[sessionId]
        }

        func takePendingParentFiles() -> [URL] {
            let files = self.pendingParentFiles.values.sorted(by: { $0.path < $1.path })
            self.pendingParentFiles.removeAll(keepingCapacity: true)
            return files
        }

        private func dependencyKey(
            for sessionId: String,
            fileURL: URL,
            metadata: CodexFileMetadata? = nil) -> String
        {
            let metadata = metadata ?? CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            return [
                "file",
                sessionId,
                CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
                metadata.fileId ?? "unknown",
                String(metadata.mtimeUnixMs),
                String(metadata.size),
                metadata.changeUnixNs.map(String.init) ?? "unknown",
            ].joined(separator: "|")
        }

        private func snapshotResolution(for sessionId: String) throws -> SnapshotResolution {
            if let cached = self.snapshotResolutions[sessionId] {
                return cached
            }
            try self.checkCancellation?()
            let lookup = try self.fileIndex.lookup(sessionId: sessionId)
            let fileURL: URL
            switch lookup {
            case let .found(foundURL):
                fileURL = foundURL
            case let .missing(dependencyKey):
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session file not found",
                    metadata: ["sessionId": sessionId])
                let resolution = SnapshotResolution(
                    dependencyKey: dependencyKey,
                    snapshots: nil,
                    isComplete: false,
                    unresolvedDependencyIsStable: true)
                self.snapshotResolutions[sessionId] = resolution
                return resolution
            case .deferred:
                let resolution = SnapshotResolution(
                    dependencyKey: nil,
                    snapshots: nil,
                    isComplete: false)
                self.snapshotResolutions[sessionId] = resolution
                return resolution
            }

            let parentMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            if let cachedResolution = self.cachedSnapshotResolution(
                for: sessionId,
                fileURL: fileURL,
                metadata: parentMetadata)
            {
                if !cachedResolution.isComplete, self.scanBudget != nil {
                    // A dependency outside the report window may exist only in the persistent
                    // partial cache. Keep advancing it until EOF proves its baseline is final.
                    self.pendingParentFiles[fileURL.standardizedFileURL.path] = fileURL
                }
                self.snapshotResolutions[sessionId] = cachedResolution
                return cachedResolution
            }
            if self.scanBudget != nil {
                // A parent discovered while parsing a child must use the same persistent,
                // resumable scan path as ordinary files. Queue it for this refresh instead of
                // opening it here and bypassing the byte or wall-clock budget.
                self.pendingParentFiles[fileURL.standardizedFileURL.path] = fileURL
                let resolution = SnapshotResolution(
                    dependencyKey: self.dependencyKey(
                        for: sessionId,
                        fileURL: fileURL,
                        metadata: parentMetadata),
                    snapshots: nil,
                    isComplete: false)
                self.snapshotResolutions[sessionId] = resolution
                return resolution
            }

            // Direct resolver construction without a scan budget is retained for focused parser
            // tests and explicit unbounded callers. Production refreshes always install a budget.
            for _ in 0..<2 {
                let dependencyKeyBeforeParse = self.dependencyKey(for: sessionId, fileURL: fileURL)
                let parsed = try CostUsageScanner.parseCodexTokenSnapshots(
                    fileURL: fileURL,
                    checkCancellation: self.checkCancellation)
                let dependencyKeyAfterParse = self.dependencyKey(for: sessionId, fileURL: fileURL)
                guard dependencyKeyBeforeParse == dependencyKeyAfterParse else { continue }

                guard let parsedSessionId = parsed.sessionId else {
                    CostUsageScanner.log.warning(
                        "Codex cost usage parent session missing session metadata",
                        metadata: ["sessionId": sessionId, "path": fileURL.path])
                    let resolution = SnapshotResolution(
                        dependencyKey: dependencyKeyAfterParse,
                        snapshots: nil,
                        isComplete: false)
                    self.snapshotResolutions[sessionId] = resolution
                    self.scanBudget?.consume(workBytes: parentMetadata.size)
                    return resolution
                }
                if parsedSessionId != sessionId {
                    CostUsageScanner.log.warning(
                        "Codex cost usage parent session resolved to mismatched session id",
                        metadata: [
                            "requestedSessionId": sessionId,
                            "resolvedSessionId": parsedSessionId,
                            "path": fileURL.path,
                        ])
                    let resolution = SnapshotResolution(
                        dependencyKey: dependencyKeyAfterParse,
                        snapshots: nil,
                        isComplete: false)
                    self.snapshotResolutions[sessionId] = resolution
                    self.scanBudget?.consume(workBytes: parentMetadata.size)
                    return resolution
                }
                let resolution = SnapshotResolution(
                    dependencyKey: dependencyKeyAfterParse,
                    snapshots: parsed.snapshots,
                    isComplete: true)
                self.snapshotResolutions[sessionId] = resolution
                self.scanBudget?.consume(workBytes: parentMetadata.size)
                return resolution
            }

            CostUsageScanner.log.warning(
                "Codex cost usage parent session changed while reading; deferring inherited baseline",
                metadata: ["sessionId": sessionId, "path": fileURL.path])
            let resolution = SnapshotResolution(dependencyKey: nil, snapshots: nil, isComplete: false)
            self.snapshotResolutions[sessionId] = resolution
            return resolution
        }

        private func cachedSnapshotResolution(
            for sessionId: String,
            fileURL: URL,
            metadata: CodexFileMetadata) -> SnapshotResolution?
        {
            let standardizedPath = fileURL.standardizedFileURL.path
            var candidates: [CostUsageFileUsage] = []
            if let direct = self.cachedFiles[fileURL.path] ?? self.cachedFiles[standardizedPath] {
                candidates.append(direct)
            }
            if let fileID = metadata.fileId,
               let aliases = self.cachedFilesByFileID[fileID]
            {
                candidates.append(contentsOf: aliases.values)
            }
            let usage = candidates
                .filter { candidate in
                    guard candidate.sessionId == sessionId,
                          candidate.codexScanFileId == metadata.fileId,
                          let anchor = candidate.codexTokenIndexAnchor,
                          anchor.indexedBytes == (candidate.parsedBytes ?? candidate.size)
                    else { return false }
                    let metadataMatches = candidate.mtimeUnixMs == metadata.mtimeUnixMs
                        && candidate.size == metadata.size
                        && candidate.codexScanChangeUnixNs == metadata.changeUnixNs
                    return metadataMatches || candidate.size < metadata.size
                }
                .max { lhs, rhs in
                    let lhsBytes = lhs.parsedBytes ?? lhs.size
                    let rhsBytes = rhs.parsedBytes ?? rhs.size
                    return lhsBytes < rhsBytes
                }
            guard let usage,
                  let cachedFileId = usage.codexScanFileId,
                  let anchor = usage.codexTokenIndexAnchor
            else { return nil }

            let indexedBytes = usage.parsedBytes ?? usage.size

            let coversCurrentFile = usage.codexScanComplete != false
                && indexedBytes >= metadata.size
            let sidecarReference = CostUsageScanner.codexTokenIndexReference(
                fileURL: fileURL,
                fileId: cachedFileId,
                anchor: anchor,
                state: usage.codexTokenSidecarState,
                isComplete: coversCurrentFile)
            if sidecarReference == nil {
                guard usage.codexTokenSnapshots != nil,
                      CostUsageScanner.codexTokenIndexAnchorMatches(
                          anchor,
                          fileURL: fileURL,
                          metadata: metadata)
                else { return nil }
            }

            // Bind the cache content and dependency key to one metadata observation. If the
            // producer appends during anchor validation, defer instead of pairing an old prefix
            // with a dependency key computed from the new file size.
            let metadataAfterValidation = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            guard metadataAfterValidation.fileId == metadata.fileId,
                  metadataAfterValidation.mtimeUnixMs == metadata.mtimeUnixMs,
                  metadataAfterValidation.size == metadata.size,
                  metadataAfterValidation.changeUnixNs == metadata.changeUnixNs
            else { return nil }
            return SnapshotResolution(
                dependencyKey: self.dependencyKey(
                    for: sessionId,
                    fileURL: fileURL,
                    metadata: metadata),
                indexedEvents: usage.codexTokenSnapshots,
                sidecarReference: sidecarReference,
                checkpoints: usage.codexTokenCheckpoints ?? [],
                indexedTimestampsMonotonic: usage.codexTokenTimestampsMonotonic == true,
                isComplete: coversCurrentFile,
                sourceURL: fileURL)
        }
    }

    struct ClaudeParseResult {
        let days: [String: [String: [Int]]]
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let timestampUnixMs: Int64?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int?
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until, calendar: options.calendar)
        let emptyReport = CostUsageDailyReport(data: [], summary: nil)
        try checkCancellation?()

        // Provider-specific by design: Codex JSONL and Claude/Vertex transcripts have distinct parsers and caches.
        switch provider {
        case .codex:
            return try self.loadCodexDaily(
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .claude:
            return try self.loadClaudeDaily(
                provider: .claude,
                range: range,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .vertexai:
            var filtered = options
            if filtered.claudeLogProviderFilter == .all {
                filtered.claudeLogProviderFilter = .vertexAIOnly
            }
            return try self.loadClaudeDaily(
                provider: .vertexai,
                range: range,
                now: now,
                options: filtered,
                checkCancellation: checkCancellation)
        default:
            return emptyReport
        }
    }

    enum CodexDailyLoadDisposition: Equatable {
        case ownedRefresh
        case deferredByConcurrentWriter
        case refreshLockUnavailable
    }

    struct CodexDailyLoadOutcome {
        let report: CostUsageDailyReport
        let disposition: CodexDailyLoadDisposition
    }

    static func loadCodexDailyReportCancellable(
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> CodexDailyLoadOutcome
    {
        let range = CostUsageDayRange(since: since, until: until, calendar: options.calendar)
        try checkCancellation?()
        return try Self.loadCodexDailyOutcome(
            range: range,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String
        let calendar: Calendar

        init(since: Date, until: Date, calendar: Calendar = .current) {
            let calendar = Self.localGregorianCalendar(matching: calendar)
            self.calendar = calendar
            self.sinceKey = Self.dayKey(from: since, calendar: calendar)
            self.untilKey = Self.dayKey(from: until, calendar: calendar)
            let scanSince = calendar.date(byAdding: .day, value: -1, to: since) ?? since
            let scanUntil = calendar.date(byAdding: .day, value: 1, to: until) ?? until
            self.scanSinceKey = Self.dayKey(from: scanSince, calendar: calendar)
            self.scanUntilKey = Self.dayKey(from: scanUntil, calendar: calendar)
        }

        private init(
            sinceKey: String,
            untilKey: String,
            scanSinceKey: String,
            scanUntilKey: String,
            calendar: Calendar)
        {
            self.sinceKey = sinceKey
            self.untilKey = untilKey
            self.scanSinceKey = scanSinceKey
            self.scanUntilKey = scanUntilKey
            self.calendar = calendar
        }

        func retainingScanCoverage(sinceKey: String, untilKey: String) -> Self {
            Self(
                sinceKey: self.sinceKey,
                untilKey: self.untilKey,
                scanSinceKey: min(self.scanSinceKey, sinceKey),
                scanUntilKey: max(self.scanUntilKey, untilKey),
                calendar: self.calendar)
        }

        static func localGregorianCalendar(matching calendar: Calendar = .current) -> Calendar {
            CostUsageLocalDay.gregorianCalendar(matching: calendar)
        }

        static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
            CostUsageLocalDay.key(from: date, calendar: calendar)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            if dayKey < since {
                return false
            }
            if dayKey > until {
                return false
            }
            return true
        }
    }

    // MARK: - Codex

    private static func defaultCodexSessionsRoot(options: Options) -> URL {
        // Provider-specific by design: Codex session discovery honors CODEX_HOME before ~/.codex.
        if let override = options.codexSessionsRoot {
            return override
        }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func codexSessionsRoots(options: Options) -> [URL] {
        let root = self.defaultCodexSessionsRoot(options: options)
        if let archived = self.codexArchivedSessionsRoot(sessionsRoot: root) {
            return [root, archived]
        }
        return [root]
    }

    private static func codexArchivedSessionsRoot(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else { return nil }
        return sessionsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private static func listCodexSessionFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        includeRecursive: Bool,
        calendar: Calendar = .current) -> [URL]
    {
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey,
            calendar: calendar).files
        let flat = self.listCodexSessionFilesFlat(root: root, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey)
        let recursive = includeRecursive ? self.listCodexLegacySessionFilesRecursive(root: root) : []
        var seen: Set<String> = []
        var out: [URL] = []
        for item in partitioned + flat + recursive where !seen.contains(item.path) {
            seen.insert(item.path)
            out.append(item)
        }
        return out
    }

    private static func cachedCodexSessionFiles(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        roots: [URL],
        excludingPaths: Set<String>) -> [URL]
    {
        let requiredParentSessionIds: Set<String> = Set(cache.files.values.compactMap { usage in
            usage.hasRetryableBufferedCodexFork || usage.deferredCodexReplayRequiresParent
                ? usage.forkedFromId
                : nil
        })
        return cache.files.compactMap { path, usage -> URL? in
            guard !excludingPaths.contains(path) else { return nil }
            let hasRelevantDay = usage.days.keys.contains {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.scanSinceKey, until: range.scanUntilKey)
            }
            let isRequiredPartialParent = usage.codexScanComplete == false
                && usage.sessionId.map(requiredParentSessionIds.contains) == true
            // Stable missing-parent buffers are dormant (not user-visible pending work), but they
            // still need a metadata-only refresh so a newly appearing parent can reactivate them.
            guard hasRelevantDay
                || isRequiredPartialParent
                || usage.hasBufferedCodexForkRetryLines
                || usage.codexDeferredForkScan == true
                || usage.codexDeferredReplayState != nil
            else {
                return nil
            }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { return nil }
            return fileURL
        }
    }

    private static func cachedCodexSessionIndex(
        cache: CostUsageCache,
        roots: [URL],
        knownExistingPaths: Set<String>) -> [String: URL]
    {
        var out: [String: URL] = [:]
        for (path, usage) in cache.files {
            guard let sessionId = usage.sessionId, !sessionId.isEmpty else { continue }
            if knownExistingPaths.contains(path) {
                out[sessionId] = URL(fileURLWithPath: path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { continue }
            out[sessionId] = fileURL
        }
        return out
    }

    private static func codexRootsFingerprint(_ roots: [URL]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for root in roots {
            out[root.standardizedFileURL.path] = 0
        }
        return out
    }

    static func codexRootsFingerprint(options: Options) -> [String: Int64] {
        self.codexRootsFingerprint(self.codexSessionsRoots(options: options))
    }

    /// Bump when the cost FORMULA changes (not the rates) so caches written by an older formula
    /// are invalidated and repriced. The pricing fingerprints below only capture rate constants,
    /// so formula-only fixes would otherwise reuse stale precomputed costs.
    private static let codexCostFormulaVersion = 2

    private static func codexPricingKey(modelsDevArtifact: ModelsDevCacheArtifact?) -> String {
        CostUsagePricingKey.codex(
            modelsDevArtifact: modelsDevArtifact,
            formulaVersion: self.codexCostFormulaVersion)
    }

    private static func codexPriorityMetadataKey(databaseURL: URL?) -> String {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        let path = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? "sqlite:\(path)" : "missing:\(path)"
    }

    private static func codexPriorityMetadataChanged(old: String?, new: String) -> Bool {
        guard let old, old != new else { return false }
        return new.hasPrefix("sqlite:")
    }

    private static func codexPriorityTurnKeys(
        _ priorityTurns: [String: CodexPriorityTurnMetadata],
        calendar: Calendar) -> [String: String]
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn, calendar: calendar) else { continue }
            partsByDay[dayKey, default: []].append([
                turnID,
                turn.model ?? "",
                turn.timestamp ?? "",
                turn.threadID ?? "",
            ].joined(separator: "|"))
        }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            out[dayKey] = self.sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
        }
        return out
    }

    private static func codexPriorityTurnIDsByDay(
        _ priorityTurns: [String: CodexPriorityTurnMetadata],
        calendar: Calendar) -> [String: [String]]
    {
        var out: [String: Set<String>] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn, calendar: calendar) else { continue }
            out[dayKey, default: []].insert(turnID)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func codexPriorityDayKey(
        _ turn: CodexPriorityTurnMetadata,
        calendar: Calendar) -> String?
    {
        guard let timestamp = turn.timestamp else { return nil }
        let dayKeyFromEpoch = Int64(timestamp).map {
            CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval($0)),
                calendar: calendar)
        }
        return dayKeyFromEpoch
            ?? self.dayKeyFromTimestamp(timestamp, calendar: calendar)
            ?? self.dayKeyFromParsedISO(timestamp, calendar: calendar)
    }

    private static func codexPriorityTurnKeysChanged(
        old: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in self.dayKeys(
            sinceKey: range.scanSinceKey,
            untilKey: range.scanUntilKey,
            calendar: range.calendar)
            where old?[dayKey] != new[dayKey]
        {
            return true
        }
        return false
    }

    private static func changedPriorityTurnIDs(
        old: [String: [String]]?,
        new: [String: [String]],
        oldKeys: [String: String]?,
        newKeys: [String: String],
        range: CostUsageDayRange) -> Set<String>
    {
        var out = Set<String>()
        for dayKey in self.dayKeys(
            sinceKey: range.scanSinceKey,
            untilKey: range.scanUntilKey,
            calendar: range.calendar)
        {
            let oldIDs = Set(old?[dayKey] ?? [])
            let newIDs = Set(new[dayKey] ?? [])
            if oldIDs != newIDs || oldKeys?[dayKey] != newKeys[dayKey] {
                out.formUnion(oldIDs)
                out.formUnion(newIDs)
            }
        }
        return out
    }

    private static func mergePriorityTurnKeys(
        existing: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: String]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(
            sinceKey: range.scanSinceKey,
            untilKey: range.scanUntilKey,
            calendar: range.calendar)
        {
            out[dayKey] = new[dayKey]
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func mergePriorityTurnIDsByDay(
        existing: [String: [String]]?,
        new: [String: [String]],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: [String]]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(
            sinceKey: range.scanSinceKey,
            untilKey: range.scanUntilKey,
            calendar: range.calendar)
        {
            out[dayKey] = new[dayKey] ?? []
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func codexTokenIndexAnchor(
        fileURL: URL,
        indexedBytes: Int64) -> CostUsageCodexTokenIndexAnchor?
    {
        let indexedBytes = max(0, indexedBytes)
        guard indexedBytes > 0 else { return nil }
        let windowStart = max(0, indexedBytes - 64 * 1024)
        let byteCount = Int(indexedBytes - windowStart)
        guard byteCount > 0 else { return nil }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(windowStart))
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                return nil
            }
            return CostUsageCodexTokenIndexAnchor(
                indexedBytes: indexedBytes,
                windowStart: windowStart,
                sha256: Self.sha256Hex(data))
        } catch {
            return nil
        }
    }

    static func codexTokenIndexAnchorMatches(
        _ anchor: CostUsageCodexTokenIndexAnchor,
        fileURL: URL,
        metadata: CodexFileMetadata) -> Bool
    {
        guard anchor.indexedBytes > 0,
              anchor.windowStart >= 0,
              anchor.windowStart < anchor.indexedBytes,
              metadata.size >= anchor.indexedBytes
        else { return false }
        return self.codexTokenIndexAnchor(
            fileURL: fileURL,
            indexedBytes: anchor.indexedBytes) == anchor
    }

    private static func listCodexRecentlyModifiedPartitionFiles(
        root: URL,
        scanSinceKey: String,
        modifiedSince: Date,
        scanBudget: CodexScanBudget,
        resumeDayKey: String?,
        calendar: Calendar = .current) -> CodexDatePartitionListing
    {
        let lookbackSinceKey = self.dayKey(
            scanSinceKey,
            addingDays: -self.codexActiveSessionLookbackDays,
            calendar: calendar)
            ?? scanSinceKey
        let lookbackUntilKey = self.dayKey(scanSinceKey, addingDays: -1, calendar: calendar)
            ?? lookbackSinceKey
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: lookbackSinceKey,
            scanUntilKey: lookbackUntilKey,
            calendar: calendar,
            scanBudget: scanBudget,
            resumeDayKey: resumeDayKey)
        return CodexDatePartitionListing(
            files: self.filterRecentlyModified(files: partitioned.files, modifiedSince: modifiedSince),
            isComplete: partitioned.isComplete,
            nextDayKey: partitioned.nextDayKey)
    }

    private static func filterRecentlyModified(files: [URL], modifiedSince: Date) -> [URL] {
        files.filter { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return false }
            guard let modifiedAt = values?.contentModificationDate else { return false }
            return modifiedAt >= modifiedSince
        }
    }

    private static func isDatePartitionComponent(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy(\.isNumber)
    }

    private static func dayKey(
        _ dayKey: String,
        addingDays days: Int,
        calendar: Calendar = .current) -> String?
    {
        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        guard let date = self.parseDayKey(dayKey, calendar: calendar) else { return nil }
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return CostUsageDayRange.dayKey(from: shifted, calendar: calendar)
    }

    private static func localStartOfDay(_ dayKey: String, calendar: Calendar) -> Date? {
        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        return self.parseDayKey(dayKey, calendar: calendar).map { calendar.startOfDay(for: $0) }
    }

    private static func dayKeys(
        sinceKey: String,
        untilKey: String,
        calendar: Calendar = .current) -> [String]
    {
        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        guard let since = self.parseDayKey(sinceKey, calendar: calendar),
              self.parseDayKey(untilKey, calendar: calendar) != nil
        else { return sinceKey <= untilKey ? [sinceKey] : [] }

        var out: [String] = []
        var cursor = since
        while CostUsageDayRange.dayKey(from: cursor, calendar: calendar) <= untilKey {
            out.append(CostUsageDayRange.dayKey(from: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if next <= cursor {
                break
            }
            cursor = next
        }
        return out
    }

    private static func listCodexRecentlyModifiedFilesRecursive(root: URL, modifiedSince: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard let modifiedAt = values?.contentModificationDate, modifiedAt >= modifiedSince else { continue }
            out.append(fileURL)
        }
        return out
    }

    static func isWithinCodexRoots(fileURL: URL, roots: [URL]) -> Bool {
        let filePath = self.codexResolvedPath(fileURL)
        return roots.contains { root in
            let rootPath = self.codexResolvedPath(root)
            if filePath == rootPath {
                return true
            }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath.hasPrefix(prefix)
        }
    }

    private static func codexResolvedPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private struct CodexDatePartitionListing {
        let files: [URL]
        let isComplete: Bool
        let nextDayKey: String?
    }

    private static func listCodexSessionFilesByDatePartition(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        calendar: Calendar = .current,
        scanBudget: CodexScanBudget? = nil,
        resumeDayKey: String? = nil) -> CodexDatePartitionListing
    {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CodexDatePartitionListing(files: [], isComplete: true, nextDayKey: nil)
        }
        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        var out: [URL] = []
        let sinceDate = Self.parseDayKey(scanSinceKey, calendar: calendar) ?? Date()
        let untilDate = Self.parseDayKey(scanUntilKey, calendar: calendar) ?? sinceDate
        let resumedDate = resumeDayKey.flatMap { Self.parseDayKey($0, calendar: calendar) }
        var date = if let resumedDate, resumedDate >= sinceDate, resumedDate <= untilDate {
            resumedDate
        } else {
            sinceDate
        }

        while date <= untilDate {
            let admittedWork: Int64
            if let scanBudget {
                switch scanBudget.admit(workBytes: 1) {
                case let .allow(allowance): admittedWork = allowance
                case .deferBudget:
                    return CodexDatePartitionListing(
                        files: out,
                        isComplete: false,
                        nextDayKey: CostUsageDayRange.dayKey(from: date, calendar: calendar))
                }
            } else {
                admittedWork = 0
            }

            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let y = String(format: "%04d", comps.year ?? 1970)
            let m = String(format: "%02d", comps.month ?? 1)
            let d = String(format: "%02d", comps.day ?? 1)

            let dayDir = root.appendingPathComponent(y, isDirectory: true)
                .appendingPathComponent(m, isDirectory: true)
                .appendingPathComponent(d, isDirectory: true)

            if let items = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            {
                for item in items where item.pathExtension.lowercased() == "jsonl" {
                    out.append(item)
                }
            }
            scanBudget?.complete(admittedWorkBytes: admittedWork, actualWorkBytes: admittedWork)

            date = calendar.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
        }

        return CodexDatePartitionListing(files: out, isComplete: true, nextDayKey: nil)
    }

    private static func codexActiveLookbackState(
        cache: CostUsageCache,
        roots: [URL],
        scanSinceKey: String,
        includeLegacyRecursiveScan: Bool) -> CostUsageCodexActiveLookbackState
    {
        let rootPaths = roots.map(Self.codexResolvedPath).sorted()
        if let cached = cache.codexActiveLookbackState,
           cached.scanSinceKey == scanSinceKey,
           cached.rootPaths == rootPaths
        {
            return cached
        }
        return CostUsageCodexActiveLookbackState(
            scanSinceKey: scanSinceKey,
            rootPaths: rootPaths,
            legacyRecursivePendingRootPaths: includeLegacyRecursiveScan ? rootPaths : [])
    }

    private static func advanceCodexActiveLookback(
        root: URL,
        range: CostUsageDayRange,
        modifiedSince: Date,
        scanBudget: CodexScanBudget,
        state: inout CostUsageCodexActiveLookbackState)
    {
        let rootPath = Self.codexResolvedPath(root)
        var completedRootPaths = Set(state.completedRootPaths)
        var pendingFilePaths = Set(state.pendingFilePaths)
        if !completedRootPaths.contains(rootPath) {
            let listing = Self.listCodexRecentlyModifiedPartitionFiles(
                root: root,
                scanSinceKey: range.scanSinceKey,
                modifiedSince: modifiedSince,
                scanBudget: scanBudget,
                resumeDayKey: state.nextDayKeyByRoot[rootPath],
                calendar: range.calendar)
            pendingFilePaths.formUnion(listing.files.map(Self.codexResolvedPath))
            if listing.isComplete {
                completedRootPaths.insert(rootPath)
                state.nextDayKeyByRoot.removeValue(forKey: rootPath)
            } else if let nextDayKey = listing.nextDayKey {
                state.nextDayKeyByRoot[rootPath] = nextDayKey
            }
        }

        var legacyPendingRoots = Set(state.legacyRecursivePendingRootPaths)
        if completedRootPaths.contains(rootPath), legacyPendingRoots.remove(rootPath) != nil {
            // This recursive walk belongs only to the cold-start cycle. Later warm cycles
            // retain the bounded partition discovery above.
            let legacy = Self.listCodexRecentlyModifiedFilesRecursive(
                root: root,
                modifiedSince: modifiedSince)
            pendingFilePaths.formUnion(legacy.map(Self.codexResolvedPath))
        }
        state.completedRootPaths = completedRootPaths.sorted()
        state.pendingFilePaths = pendingFilePaths.sorted()
        state.legacyRecursivePendingRootPaths = legacyPendingRoots.sorted()
    }

    private static func appendPendingCodexActiveLookbackFiles(
        state: inout CostUsageCodexActiveLookbackState,
        roots: [URL],
        seenPaths: inout Set<String>,
        files: inout [URL])
    {
        state.pendingFilePaths = state.pendingFilePaths.filter { path in
            FileManager.default.fileExists(atPath: path)
                && Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: path), roots: roots)
        }
        var seenFileIDs = Set(files.compactMap { Self.codexFileMetadata(fileURL: $0).fileId })
        for path in state.pendingFilePaths where !seenPaths.contains(path) {
            let fileID = Self.codexFileMetadata(fileURL: URL(fileURLWithPath: path)).fileId
            if let fileID, !seenFileIDs.insert(fileID).inserted {
                continue
            }
            seenPaths.insert(path)
            files.append(URL(fileURLWithPath: path))
        }
    }

    private static func finalizedCodexActiveLookbackState(
        _ state: CostUsageCodexActiveLookbackState,
        cache: CostUsageCache,
        retainCompletedState: Bool = false) -> CostUsageCodexActiveLookbackState?
    {
        var state = state
        state.pendingFilePaths.removeAll { path in
            guard FileManager.default.fileExists(atPath: path) else { return true }
            let fileURL = URL(fileURLWithPath: path)
            let metadata = Self.codexFileMetadata(fileURL: fileURL)
            let fileID = metadata.fileId
            if let fileID {
                return cache.files.values.contains { usage in
                    usage.codexScanFileId == fileID
                        && Self.cachedCodexUsageCoversCurrentFile(usage, metadata: metadata)
                }
            }
            return cache.files[path].map { usage in
                Self.cachedCodexUsageCoversCurrentFile(usage, metadata: metadata)
            } == true
        }
        let isComplete = Set(state.completedRootPaths) == Set(state.rootPaths)
            && state.pendingFilePaths.isEmpty
            && state.legacyRecursivePendingRootPaths.isEmpty
            && !retainCompletedState
        return isComplete ? nil : state
    }

    private static func cachedCodexUsageCoversCurrentFile(
        _ usage: CostUsageFileUsage,
        metadata: CodexFileMetadata) -> Bool
    {
        guard usage.codexScanFileId == metadata.fileId,
              usage.mtimeUnixMs == metadata.mtimeUnixMs,
              usage.size == metadata.size,
              usage.codexScanChangeUnixNs == metadata.changeUnixNs
        else { return false }
        if usage.hasSettledDeferredCodexFork || usage.hasSettledDeferredCodexReplay { return true }
        let indexedBytes = usage.codexTokenIndexAnchor?.indexedBytes
            ?? usage.parsedBytes
            ?? usage.size
        return usage.codexScanComplete != false
            && indexedBytes >= metadata.size
            && !usage.hasRetryableBufferedCodexFork
    }

    private static func listCodexSessionFilesFlat(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        for item in items where item.pathExtension.lowercased() == "jsonl" {
            if let dayKey = Self.dayKeyFromFilename(item.lastPathComponent) {
                if !CostUsageDayRange.isInRange(dayKey: dayKey, since: scanSinceKey, until: scanUntilKey) {
                    continue
                }
            }
            out.append(item)
        }
        return out
    }

    private static func listCodexLegacySessionFilesRecursive(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if Self.isCodexDatePartitionAncestor(item, rootPath: rootPath) {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            out.append(item)
        }
        return out
    }

    private static func isCodexDatePartitionAncestor(_ url: URL, rootPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let parts = relative.split(separator: "/")
        guard parts.count == 1 else { return false }
        return Self.isDatePartitionComponent(String(parts[0]), length: 4)
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = self.codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    struct CodexSessionMetadata: Codable {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
        let projectPath: String?
        let isSubagentThread: Bool
        let subagentHistoryStartOrdinal: Int?
    }

    struct CodexTurnContextMetadata: Codable {
        let timestamp: String?
        let model: String?
        let cwd: String?
        let title: String?
    }

    struct CodexTokenCountRecord: Codable {
        let timestamp: String
        let model: String?
        let turnID: String?
        let last: CostUsageCodexTotals?
        let total: CostUsageCodexTotals?
    }

    enum CodexFastLine: Codable {
        case sessionMeta(CodexSessionMetadata)
        case turnContext(CodexTurnContextMetadata)
        case interAgentCommunication(triggerTurn: Bool)
        case taskStarted(turnID: String?)
        case tokenCount(CodexTokenCountRecord)

        var requiresValidTimestamp: Bool {
            switch self {
            case .sessionMeta:
                false
            case .turnContext, .interAgentCommunication, .taskStarted, .tokenCount:
                true
            }
        }
    }

    struct CodexBufferedFastLine: Codable {
        let lineIndex: Int
        let ordinal: Int?
        let startOffset: Int64?
        let endOffset: Int64?
        let line: CodexFastLine

        init(
            lineIndex: Int,
            ordinal: Int?,
            startOffset: Int64? = nil,
            endOffset: Int64? = nil,
            line: CodexFastLine)
        {
            self.lineIndex = lineIndex
            self.ordinal = ordinal
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.line = line
        }
    }

    /// Legacy classification buffers are a one-pass fast path, never an unbounded persistence
    /// format. Above either cap the scanner keeps only a constant-size classifier/replay state.
    static let codexBufferedFastLineCountLimit = 512
    static let codexBufferedFastLineByteLimit = 512 * 1024

    private static func codexBufferedFastLineApproximateBytes(_ line: CodexBufferedFastLine) -> Int {
        func stringBytes(_ value: String?) -> Int {
            value?.utf8.count ?? 0
        }
        let payloadBytes: Int = switch line.line {
        case let .sessionMeta(metadata):
            stringBytes(metadata.sessionId)
                + stringBytes(metadata.forkedFromId)
                + stringBytes(metadata.forkTimestamp)
                + stringBytes(metadata.projectPath)
        case let .turnContext(metadata):
            stringBytes(metadata.timestamp)
                + stringBytes(metadata.model)
                + stringBytes(metadata.cwd)
                + stringBytes(metadata.title)
        case .interAgentCommunication:
            1
        case let .taskStarted(turnID):
            stringBytes(turnID)
        case let .tokenCount(record):
            stringBytes(record.timestamp) + stringBytes(record.model) + stringBytes(record.turnID) + 160
        }
        return 64 + payloadBytes
    }

    private static func normalizedBoundedCodexSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(256))
    }

    private static func initialLegacySubagentShapeState(
        leafSessionId: String?,
        bufferedApproximateBytes: Int = 0) -> CostUsageCodexLegacySubagentShapeState
    {
        CostUsageCodexLegacySubagentShapeState(
            leafSessionId: self.normalizedBoundedCodexSessionID(leafSessionId),
            observedAuthoritativeMetadata: false,
            hasEmbeddedAncestor: false,
            ancestorSessionIds: [],
            lastRawTotals: nil,
            pendingTurnContextLineIndex: nil,
            pendingTurnContextStartOffset: nil,
            pendingTurnContextBaseline: nil,
            ownedSuffixStartLineIndex: nil,
            ownedSuffixStartOffset: nil,
            ownedSuffixBaseline: nil,
            parentTotalsAtBoundary: nil,
            locallyConfirmedBoundary: false,
            inspectedOwnedSuffixFirstTotal: false,
            observedTurnContext: false,
            nextLineIndex: 0,
            bufferedApproximateBytes: bufferedApproximateBytes)
    }

    private static func observeLegacySubagentShape(
        _ line: CodexBufferedFastLine,
        hasExplicitParent: Bool,
        state: inout CostUsageCodexLegacySubagentShapeState)
    {
        state.nextLineIndex = max(state.nextLineIndex, line.lineIndex + 1)
        switch line.line {
        case let .sessionMeta(metadata):
            let metadataID = self.normalizedBoundedCodexSessionID(metadata.sessionId)
            let isEmbeddedAncestor: Bool = if !state.observedAuthoritativeMetadata {
                state.leafSessionId == nil && metadataID != nil
            } else if let leafID = state.leafSessionId {
                metadataID != leafID
            } else {
                true
            }
            state.observedAuthoritativeMetadata = true
            if isEmbeddedAncestor {
                state.hasEmbeddedAncestor = true
                if let metadataID,
                   metadataID != state.leafSessionId,
                   !state.ancestorSessionIds.contains(metadataID),
                   state.ancestorSessionIds.count < 2
                {
                    state.ancestorSessionIds.append(metadataID)
                }
                // A later ancestor proves that every earlier candidate was replay history.
                state.ownedSuffixStartLineIndex = nil
                state.ownedSuffixStartOffset = nil
                state.ownedSuffixBaseline = nil
                state.parentTotalsAtBoundary = nil
                state.locallyConfirmedBoundary = false
                state.inspectedOwnedSuffixFirstTotal = false
            }
            state.pendingTurnContextLineIndex = nil
            state.pendingTurnContextStartOffset = nil
            state.pendingTurnContextBaseline = nil

        case .turnContext:
            let isFirstTurnContext = !state.observedTurnContext
            state.observedTurnContext = true
            let acceptsBoundary = state.hasEmbeddedAncestor || (hasExplicitParent && isFirstTurnContext)
            if acceptsBoundary, let baseline = state.lastRawTotals {
                state.pendingTurnContextLineIndex = line.lineIndex
                state.pendingTurnContextStartOffset = line.startOffset
                state.pendingTurnContextBaseline = baseline
            } else {
                state.pendingTurnContextLineIndex = nil
                state.pendingTurnContextStartOffset = nil
                state.pendingTurnContextBaseline = nil
            }

        case let .interAgentCommunication(triggerTurn):
            if state.ownedSuffixStartLineIndex == nil,
               triggerTurn,
               let pendingLineIndex = state.pendingTurnContextLineIndex,
               line.lineIndex == pendingLineIndex + 1,
               let boundaryOffset = state.pendingTurnContextStartOffset,
               let boundaryBaseline = state.pendingTurnContextBaseline,
               state.hasEmbeddedAncestor
               || boundaryBaseline.input > 0
               || boundaryBaseline.cached > 0
               || boundaryBaseline.output > 0
            {
                state.ownedSuffixStartLineIndex = pendingLineIndex
                state.ownedSuffixStartOffset = boundaryOffset
                state.ownedSuffixBaseline = boundaryBaseline
                state.parentTotalsAtBoundary = boundaryBaseline
                state.locallyConfirmedBoundary = false
                state.inspectedOwnedSuffixFirstTotal = false
            }
            state.pendingTurnContextLineIndex = nil
            state.pendingTurnContextStartOffset = nil
            state.pendingTurnContextBaseline = nil

        case let .tokenCount(record):
            if !state.inspectedOwnedSuffixFirstTotal,
               let suffixBaseline = state.ownedSuffixBaseline,
               let total = record.total
            {
                state.inspectedOwnedSuffixFirstTotal = true
                if let last = record.last,
                   self.codexTotalsEqual(total, last),
                   !self.codexTotalsAtLeast(total, suffixBaseline)
                {
                    state.ownedSuffixBaseline = .init(input: 0, cached: 0, output: 0)
                } else if let last = record.last,
                          self.codexTotalsAtLeast(total, last),
                          self.codexTotalsEqual(
                              self.codexTotalDelta(from: last, to: total),
                              suffixBaseline)
                {
                    state.locallyConfirmedBoundary = true
                }
            }
            if let total = record.total {
                state.lastRawTotals = total
            }
            state.pendingTurnContextLineIndex = nil
            state.pendingTurnContextStartOffset = nil
            state.pendingTurnContextBaseline = nil

        case .taskStarted:
            break
        }
    }

    private static let codexJSONFieldCachedInputTokens = Array("cached_input_tokens".utf8)
    private static let codexJSONFieldCacheReadInputTokens = Array("cache_read_input_tokens".utf8)
    private static let codexJSONFieldForkedFromId = Array("forked_from_id".utf8)
    private static let codexJSONFieldForkedFromIdCamel = Array("forkedFromId".utf8)
    private static let codexJSONFieldId = Array("id".utf8)
    private static let codexJSONFieldInfo = Array("info".utf8)
    private static let codexJSONFieldInputTokens = Array("input_tokens".utf8)
    private static let codexJSONFieldLastTokenUsage = Array("last_token_usage".utf8)
    private static let codexJSONFieldModel = Array("model".utf8)
    private static let codexJSONFieldModelName = Array("model_name".utf8)
    private static let codexJSONFieldOutputTokens = Array("output_tokens".utf8)
    private static let codexJSONFieldOrdinal = Array("ordinal".utf8)
    private static let codexJSONFieldReasoningOutputTokens = Array("reasoning_output_tokens".utf8)
    private static let codexJSONFieldParentSessionId = Array("parent_session_id".utf8)
    private static let codexJSONFieldParentSessionIdCamel = Array("parentSessionId".utf8)
    private static let codexJSONFieldPayload = Array("payload".utf8)
    private static let codexJSONFieldSource = Array("source".utf8)
    private static let codexJSONFieldSubagent = Array("subagent".utf8)
    private static let codexJSONFieldSubagentHistoryStartOrdinal =
        Array("subagent_history_start_ordinal".utf8)
    private static let codexJSONFieldSessionId = Array("session_id".utf8)
    private static let codexJSONFieldSessionIdCamel = Array("sessionId".utf8)
    private static let codexJSONFieldTimestamp = Array("timestamp".utf8)
    private static let codexJSONFieldTitle = Array("title".utf8)
    private static let codexJSONFieldName = Array("name".utf8)
    private static let codexJSONFieldTotalTokenUsage = Array("total_token_usage".utf8)
    private static let codexJSONFieldTriggerTurn = Array("trigger_turn".utf8)
    private static let codexJSONFieldTurnId = Array("turn_id".utf8)
    private static let codexJSONFieldTurnIdCamel = Array("turnId".utf8)
    private static let codexJSONFieldType = Array("type".utf8)
    private static let codexJSONFieldCwd = Array("cwd".utf8)
    private static let codexJSONFieldCurrentWorkingDirectory = Array("current_working_directory".utf8)
    private static let codexJSONFieldCurrentWorkingDirectoryCamel = Array("currentWorkingDirectory".utf8)

    static func codexModelEvidence(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func codexTurnContextModel(
        payloadModel: String?,
        payloadModelName: String?,
        infoModel: String?,
        infoModelName: String?) -> String?
    {
        var sawCandidate = false
        for candidate in [payloadModel, payloadModelName, infoModel, infoModelName] {
            guard let candidate else { continue }
            sawCandidate = true
            if let model = self.codexModelEvidence(candidate) {
                return model
            }
        }
        // nil means the context omitted every model field; an empty value explicitly clears stale context.
        return sawCandidate ? "" : nil
    }

    private static func codexForkParentId(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        for key in ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func codexForkParentId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in payloadRange: Range<Int>) -> String?
    {
        for key in [
            self.codexJSONFieldForkedFromId,
            self.codexJSONFieldForkedFromIdCamel,
            self.codexJSONFieldParentSessionId,
            self.codexJSONFieldParentSessionIdCamel,
        ] {
            guard let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    private static func codexIsSubagentThread(from payload: [String: Any]?) -> Bool {
        guard let payload else { return false }
        if let source = payload["source"] as? String {
            return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subagent"
        }
        if let source = payload["source"] as? [String: Any] {
            return source["subagent"] is String || source["subagent"] is [String: Any]
        }
        return false
    }

    private static func codexIsSubagentThread(
        from bytes: UnsafeBufferPointer<UInt8>,
        in payloadRange: Range<Int>) -> Bool
    {
        if let source = extractJSONByteStringField(
            self.codexJSONFieldSource,
            from: bytes,
            in: payloadRange,
            atDepth: 1)
        {
            return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subagent"
        }
        guard let sourceRange = extractJSONByteObjectField(
            self.codexJSONFieldSource,
            from: bytes,
            in: payloadRange,
            atDepth: 1)
        else { return false }
        return extractJSONByteStringField(
            self.codexJSONFieldSubagent,
            from: bytes,
            in: sourceRange,
            atDepth: 1) != nil
            || extractJSONByteObjectField(
                self.codexJSONFieldSubagent,
                from: bytes,
                in: sourceRange,
                atDepth: 1) != nil
    }

    private static func codexTurnID(from bytes: UnsafeBufferPointer<UInt8>, in payloadRange: Range<Int>) -> String? {
        for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
            if let value = extractJSONByteStringField(key, from: bytes, in: payloadRange, atDepth: 1), !value.isEmpty {
                return value
            }
        }
        if let infoRange = extractJSONByteObjectField(codexJSONFieldInfo, from: bytes, in: payloadRange, atDepth: 1) {
            for key in [self.codexJSONFieldTurnId, self.codexJSONFieldTurnIdCamel, self.codexJSONFieldId] {
                if let value = extractJSONByteStringField(key, from: bytes, in: infoRange, atDepth: 1), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func codexSessionId(
        from bytes: UnsafeBufferPointer<UInt8>,
        in rootRange: Range<Int>,
        payloadRange: Range<Int>?) -> String?
    {
        // `session_id` identifies the shared multi-agent tree. `id` identifies this rollout/thread,
        // and both fields have appeared at either metadata level.
        let candidates: [String?] = [
            payloadRange.flatMap {
                Self.extractJSONByteStringField(Self.codexJSONFieldId, from: bytes, in: $0, atDepth: 1)
            },
            Self.extractJSONByteStringField(Self.codexJSONFieldId, from: bytes, in: rootRange, atDepth: 1),
            payloadRange.flatMap {
                Self.extractJSONByteStringField(Self.codexJSONFieldSessionId, from: bytes, in: $0, atDepth: 1)
            },
            payloadRange.flatMap {
                Self.extractJSONByteStringField(Self.codexJSONFieldSessionIdCamel, from: bytes, in: $0, atDepth: 1)
            },
            Self.extractJSONByteStringField(Self.codexJSONFieldSessionId, from: bytes, in: rootRange, atDepth: 1),
            Self.extractJSONByteStringField(Self.codexJSONFieldSessionIdCamel, from: bytes, in: rootRange, atDepth: 1),
        ]
        for value in candidates where value?.isEmpty == false {
            return value
        }
        return nil
    }

    static func normalizedCodexProjectPath(_ rawPath: String?) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private static func codexProjectPath(
        from bytes: UnsafeBufferPointer<UInt8>,
        payloadRange: Range<Int>?) -> String?
    {
        guard let payloadRange else { return nil }
        return Self.normalizedCodexProjectPath(
            Self.extractJSONByteStringField(Self.codexJSONFieldCwd, from: bytes, in: payloadRange, atDepth: 1))
    }

    private static func codexTotals(
        from bytes: UnsafeBufferPointer<UInt8>,
        in objectRange: Range<Int>?) -> CostUsageCodexTotals?
    {
        guard let objectRange else { return nil }
        let input = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldInputTokens, from: bytes, in: objectRange, atDepth: 1) ?? 0)
        let cached = max(
            0,
            Self.extractJSONByteIntField(Self.codexJSONFieldCachedInputTokens, from: bytes, in: objectRange, atDepth: 1)
                ?? Self.extractJSONByteIntField(
                    Self.codexJSONFieldCacheReadInputTokens,
                    from: bytes,
                    in: objectRange,
                    atDepth: 1)
                ?? 0)
        let output = max(
            0,
            Self
                .extractJSONByteIntField(Self.codexJSONFieldOutputTokens, from: bytes, in: objectRange, atDepth: 1) ??
                0)
        let reasoning = Self.extractJSONByteIntField(
            Self.codexJSONFieldReasoningOutputTokens,
            from: bytes,
            in: objectRange,
            atDepth: 1).map { min(max(0, $0), output) }
        return CostUsageCodexTotals(input: input, cached: cached, output: output, reasoning: reasoning)
    }

    private static func codexInterAgentCommunication(
        from bytes: UnsafeBufferPointer<UInt8>,
        in objectRange: Range<Int>) -> CodexFastLine?
    {
        guard let payloadRange = extractJSONByteObjectField(
            codexJSONFieldPayload,
            from: bytes,
            in: objectRange,
            atDepth: 1),
            let triggerTurn = extractJSONByteBoolField(
                codexJSONFieldTriggerTurn,
                from: bytes,
                in: payloadRange,
                atDepth: 1)
        else { return nil }
        return .interAgentCommunication(triggerTurn: triggerTurn)
    }

    // swiftlint:disable:next function_body_length
    private static func parseCodexFastLine(_ bytes: Data) -> CodexFastLine? {
        bytes.withUnsafeBytes { rawBytes in
            let rawBuffer = rawBytes.bindMemory(to: UInt8.self)
            guard !rawBuffer.isEmpty else { return nil }
            let objectRange = 0..<rawBuffer.count
            guard let type = Self.extractJSONByteStringField(
                Self.codexJSONFieldType,
                from: rawBuffer,
                in: objectRange,
                atDepth: 1)
            else { return nil }

            switch type {
            case "session_meta":
                let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                return .sessionMeta(CodexSessionMetadata(
                    sessionId: Self.codexSessionId(from: rawBuffer, in: objectRange, payloadRange: payloadRange),
                    forkedFromId: payloadRange.flatMap { Self.codexForkParentId(from: rawBuffer, in: $0) },
                    forkTimestamp: payloadRange.flatMap {
                        Self.extractJSONByteStringField(
                            Self.codexJSONFieldTimestamp,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    } ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldTimestamp,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1),
                    projectPath: Self.codexProjectPath(from: rawBuffer, payloadRange: payloadRange),
                    isSubagentThread: payloadRange.map {
                        Self.codexIsSubagentThread(from: rawBuffer, in: $0)
                    } ?? false,
                    subagentHistoryStartOrdinal: payloadRange.flatMap {
                        Self.extractJSONByteIntField(
                            Self.codexJSONFieldSubagentHistoryStartOrdinal,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    }))

            case "turn_context":
                let timestamp = Self.extractJSONByteStringField(
                    Self.codexJSONFieldTimestamp,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                else {
                    return .turnContext(CodexTurnContextMetadata(
                        timestamp: timestamp,
                        model: nil,
                        cwd: nil,
                        title: nil))
                }
                let infoRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldInfo,
                    from: rawBuffer,
                    in: payloadRange,
                    atDepth: 1)
                let model = Self.codexTurnContextModel(
                    payloadModel: Self.extractJSONByteStringFieldAllowingEmpty(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1),
                    payloadModelName: Self.extractJSONByteStringFieldAllowingEmpty(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1),
                    infoModel: infoRange.flatMap {
                        Self.extractJSONByteStringFieldAllowingEmpty(
                            Self.codexJSONFieldModel,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    },
                    infoModelName: infoRange.flatMap {
                        Self.extractJSONByteStringFieldAllowingEmpty(
                            Self.codexJSONFieldModelName,
                            from: rawBuffer,
                            in: $0,
                            atDepth: 1)
                    })
                let cwd = Self.extractJSONByteStringField(
                    Self.codexJSONFieldCwd,
                    from: rawBuffer,
                    in: payloadRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldCurrentWorkingDirectory,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldCurrentWorkingDirectoryCamel,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                let title = Self.extractJSONByteStringField(
                    Self.codexJSONFieldTitle,
                    from: rawBuffer,
                    in: payloadRange,
                    atDepth: 1)
                    ?? Self.extractJSONByteStringField(
                        Self.codexJSONFieldName,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                return .turnContext(CodexTurnContextMetadata(
                    timestamp: timestamp,
                    model: model,
                    cwd: cwd,
                    title: title))

            case "inter_agent_communication_metadata":
                // Compact Codex JSONL uses this exact spelling. Whitespace/escaped variants fall
                // through to Foundation so a fast-path miss cannot change boundary semantics.
                return Self.codexInterAgentCommunication(from: rawBuffer, in: objectRange)

            case "event_msg":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1),
                    let payloadType = Self.extractJSONByteStringField(
                        Self.codexJSONFieldType,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1)
                else { return nil }

                if payloadType == "task_started" {
                    return .taskStarted(turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange))
                }

                guard payloadType == "token_count",
                      let timestamp = Self.extractJSONByteStringField(
                          Self.codexJSONFieldTimestamp,
                          from: rawBuffer,
                          in: objectRange,
                          atDepth: 1),
                      let infoRange = Self.extractJSONByteObjectField(
                          Self.codexJSONFieldInfo,
                          from: rawBuffer,
                          in: payloadRange,
                          atDepth: 1)
                else { return nil }

                let model = Self.codexModelEvidence(Self.extractJSONByteStringField(
                    Self.codexJSONFieldModel,
                    from: rawBuffer,
                    in: infoRange,
                    atDepth: 1))
                    ?? Self.codexModelEvidence(Self.extractJSONByteStringField(
                        Self.codexJSONFieldModelName,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                    ?? Self.codexModelEvidence(Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: payloadRange,
                        atDepth: 1))
                    ?? Self.codexModelEvidence(Self.extractJSONByteStringField(
                        Self.codexJSONFieldModel,
                        from: rawBuffer,
                        in: objectRange,
                        atDepth: 1))
                let total = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldTotalTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                let last = Self.codexTotals(
                    from: rawBuffer,
                    in: Self.extractJSONByteObjectField(
                        Self.codexJSONFieldLastTokenUsage,
                        from: rawBuffer,
                        in: infoRange,
                        atDepth: 1))
                return .tokenCount(CodexTokenCountRecord(
                    timestamp: timestamp,
                    model: model,
                    turnID: Self.codexTurnID(from: rawBuffer, in: payloadRange),
                    last: last,
                    total: total))

            default:
                return nil
            }
        }
    }

    private static func codexFastLineTimestampValidity(_ bytes: Data) -> Bool? {
        let timestamp = bytes.withUnsafeBytes { rawBytes in
            let rawBuffer = rawBytes.bindMemory(to: UInt8.self)
            guard !rawBuffer.isEmpty else { return nil as String? }
            return Self.extractJSONByteStringField(
                Self.codexJSONFieldTimestamp,
                from: rawBuffer,
                in: 0..<rawBuffer.count,
                atDepth: 1)
        }
        guard let timestamp else { return nil }
        return (Self.dayKeyFromTimestamp(timestamp) ?? Self.dayKeyFromParsedISO(timestamp)) != nil
    }

    private static func codexLineOrdinal(_ bytes: Data) -> Int? {
        bytes.withUnsafeBytes { rawBytes in
            let rawBuffer = rawBytes.bindMemory(to: UInt8.self)
            guard !rawBuffer.isEmpty else { return nil }
            return Self.extractJSONByteIntField(
                Self.codexJSONFieldOrdinal,
                from: rawBuffer,
                in: 0..<rawBuffer.count,
                atDepth: 1)
        }
    }

    private struct CodexFoundationFallbackLine {
        let fastLine: CodexFastLine
        let ordinal: Int?
    }

    /// Decode whitespace/escaped JSON that the byte parser intentionally declines. Foundation's
    /// JSON stack must unwind before the caller enters token accounting and subagent routing;
    /// keeping both operations in one autorelease-pool closure can overflow the small Swift
    /// Testing worker stack on a copied-prefix boundary.
    @inline(never)
    private static func decodeCodexFoundationFallbackLine(
        _ bytes: Data) -> CodexFoundationFallbackLine?
    {
        autoreleasepool {
            guard
                let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                let type = obj["type"] as? String
            else { return nil }
            let ordinal = (obj["ordinal"] as? NSNumber)?.intValue

            if type == "session_meta" {
                guard let metadata = Self.codexSessionMetadata(from: obj) else { return nil }
                return CodexFoundationFallbackLine(
                    fastLine: .sessionMeta(metadata),
                    ordinal: ordinal)
            }

            guard let tsText = obj["timestamp"] as? String else { return nil }
            guard Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) != nil
            else { return nil }

            if type == "inter_agent_communication_metadata" {
                let payload = obj["payload"] as? [String: Any]
                return CodexFoundationFallbackLine(
                    fastLine: .interAgentCommunication(
                        triggerTurn: payload?["trigger_turn"] as? Bool == true),
                    ordinal: ordinal)
            }

            if type == "turn_context" {
                var metadata = CodexTurnContextMetadata(
                    timestamp: tsText,
                    model: nil,
                    cwd: nil,
                    title: nil)
                if let payload = obj["payload"] as? [String: Any] {
                    let info = payload["info"] as? [String: Any]
                    metadata = CodexTurnContextMetadata(
                        timestamp: tsText,
                        model: Self.codexTurnContextModel(
                            payloadModel: payload["model"] as? String,
                            payloadModelName: payload["model_name"] as? String,
                            infoModel: info?["model"] as? String,
                            infoModelName: info?["model_name"] as? String),
                        cwd: payload["cwd"] as? String
                            ?? payload["current_working_directory"] as? String
                            ?? payload["currentWorkingDirectory"] as? String,
                        title: payload["title"] as? String ?? payload["name"] as? String)
                }
                return CodexFoundationFallbackLine(
                    fastLine: .turnContext(metadata),
                    ordinal: ordinal)
            }

            guard type == "event_msg" else { return nil }
            guard let payload = obj["payload"] as? [String: Any] else { return nil }
            if (payload["type"] as? String) == "task_started" {
                return CodexFoundationFallbackLine(
                    fastLine: .taskStarted(turnID: Self.codexTurnID(from: payload)),
                    ordinal: ordinal)
            }
            guard (payload["type"] as? String) == "token_count" else { return nil }

            let info = payload["info"] as? [String: Any]
            let modelFromInfo = Self.codexModelEvidence(info?["model"] as? String)
                ?? Self.codexModelEvidence(info?["model_name"] as? String)
                ?? Self.codexModelEvidence(payload["model"] as? String)
                ?? Self.codexModelEvidence(obj["model"] as? String)

            func toInt(_ value: Any?) -> Int {
                (value as? NSNumber)?.intValue ?? 0
            }

            func tokenTotals(_ usage: [String: Any]) -> CostUsageCodexTotals {
                let output = max(0, toInt(usage["output_tokens"]))
                return CostUsageCodexTotals(
                    input: max(0, toInt(usage["input_tokens"])),
                    cached: max(0, toInt(
                        usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])),
                    output: output,
                    reasoning: (usage["reasoning_output_tokens"] as? NSNumber)
                        .map { min(max(0, $0.intValue), output) })
            }

            return CodexFoundationFallbackLine(
                fastLine: .tokenCount(CodexTokenCountRecord(
                    timestamp: tsText,
                    model: modelFromInfo,
                    turnID: Self.codexTurnID(from: payload),
                    last: (info?["last_token_usage"] as? [String: Any]).map(tokenTotals),
                    total: (info?["total_token_usage"] as? [String: Any]).map(tokenTotals))),
                ordinal: ordinal)
        }
    }

    static func parseCodexSessionIdentifier(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> String?
    {
        try self.parseCodexSessionMetadata(fileURL: fileURL, checkCancellation: checkCancellation)?.sessionId
    }

    static let codexSessionMetadataMaxLineBytes = 256 * 1024
    private static let codexForkMetadataPreflightMaxBytes = Int64(Self.codexSessionMetadataMaxLineBytes)

    private struct CodexSessionMetadataScanResult {
        let metadata: CodexSessionMetadata?
        let bytesRead: Int64
    }

    private static func codexSessionMetadata(from obj: [String: Any]) -> CodexSessionMetadata? {
        guard obj["type"] as? String == "session_meta" else { return nil }
        let payload = obj["payload"] as? [String: Any]
        return CodexSessionMetadata(
            sessionId: payload?["id"] as? String
                ?? obj["id"] as? String
                ?? payload?["session_id"] as? String
                ?? payload?["sessionId"] as? String
                ?? obj["session_id"] as? String
                ?? obj["sessionId"] as? String,
            forkedFromId: Self.codexForkParentId(from: payload),
            forkTimestamp: payload?["timestamp"] as? String
                ?? obj["timestamp"] as? String,
            projectPath: Self.normalizedCodexProjectPath(payload?["cwd"] as? String),
            isSubagentThread: Self.codexIsSubagentThread(from: payload),
            subagentHistoryStartOrdinal: (payload?["subagent_history_start_ordinal"] as? NSNumber)?.intValue)
    }

    private static func parseCodexSessionMetadata(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> CodexSessionMetadata?
    {
        try self.scanCodexSessionMetadata(
            fileURL: fileURL,
            maxBytesToRead: nil,
            checkCancellation: checkCancellation).metadata
    }

    /// Reads only enough of the JSONL prefix to find authoritative session metadata. Callers that
    /// pass a limit can account for this work separately and never turn a metadata lookup into an
    /// accidental full-file scan.
    private static func scanCodexSessionMetadata(
        fileURL: URL,
        maxBytesToRead: Int64?,
        checkCancellation: CancellationCheck?) throws -> CodexSessionMetadataScanResult
    {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            self.log.warning(
                "Codex cost usage failed to open session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return CodexSessionMetadataScanResult(metadata: nil, bytesRead: 0)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var discardingOversizedLine = false
        var bytesRead: Int64 = 0
        var didReachEOF = false

        do {
            var matchedMetadata: CodexSessionMetadata?
            while true {
                let remaining = maxBytesToRead.map { max(0, $0 - bytesRead) }
                guard remaining != 0 else { break }
                let reachedEOFThisRead = try autoreleasepool { () throws -> Bool in
                    let readCount = min(64 * 1024, Int(remaining ?? Int64(64 * 1024)))
                    guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                        return true
                    }
                    try checkCancellation?()
                    bytesRead += Int64(chunk.count)

                    var segmentStart = chunk.startIndex
                    while segmentStart < chunk.endIndex {
                        let newlineIndex = chunk[segmentStart...].firstIndex(of: 0x0A)
                        let segmentEnd = newlineIndex ?? chunk.endIndex

                        if !discardingOversizedLine {
                            let segmentCount = chunk.distance(from: segmentStart, to: segmentEnd)
                            let remainingBytes = Self.codexSessionMetadataMaxLineBytes - buffer.count
                            if segmentCount <= remainingBytes {
                                buffer.append(contentsOf: chunk[segmentStart..<segmentEnd])
                            } else {
                                // Release the retained prefix immediately. The buffer never exceeds the line limit.
                                buffer.removeAll(keepingCapacity: false)
                                discardingOversizedLine = true
                            }
                        }

                        guard let newlineIndex else { break }
                        if !discardingOversizedLine,
                           let metadata = Self.parseCodexSessionMetadataLine(buffer)
                        {
                            matchedMetadata = metadata
                            break
                        }
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversizedLine = false
                        segmentStart = chunk.index(after: newlineIndex)
                    }

                    return false
                }
                if let matchedMetadata {
                    return CodexSessionMetadataScanResult(metadata: matchedMetadata, bytesRead: bytesRead)
                }
                if reachedEOFThisRead {
                    // Keep this state outside the autorelease pool so a final unterminated JSON
                    // record is parsed only at real EOF, never merely because a bounded read ended.
                    didReachEOF = true
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while reading session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return CodexSessionMetadataScanResult(metadata: nil, bytesRead: bytesRead)
        }

        // A bounded read that lands exactly on the immutable EOF has consumed a complete final
        // record even though no additional empty read was needed to prove it.
        if !didReachEOF {
            didReachEOF = bytesRead >= Self.codexFileMetadata(fileURL: fileURL).size
        }
        if didReachEOF,
           !discardingOversizedLine,
           let metadata = Self.parseCodexSessionMetadataLine(buffer)
        {
            return CodexSessionMetadataScanResult(metadata: metadata, bytesRead: bytesRead)
        }
        return CodexSessionMetadataScanResult(metadata: nil, bytesRead: bytesRead)
    }

    private static func parseCodexSessionMetadataLine(_ lineData: Data) -> CodexSessionMetadata? {
        guard !lineData.isEmpty else { return nil }
        if case let .sessionMeta(metadata) = parseCodexFastLine(lineData) {
            return metadata
        }
        return autoreleasepool {
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { return nil }
            return Self.codexSessionMetadata(from: obj)
        }
    }

    static func codexFileIsSubagentThread(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> Bool
    {
        try self.parseCodexSessionMetadata(
            fileURL: fileURL,
            checkCancellation: checkCancellation)?.isSubagentThread == true
    }

    private static func parseCodexTokenSnapshots(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> (
        sessionId: String?,
        snapshots: [CodexTimestampedTotals])
    {
        var sessionId: String?
        var accumulator = CodexSnapshotAccumulator()
        var snapshots: [CodexTimestampedTotals] = []
        var warnedAboutUnparsedTimestamp = false

        func parsedSnapshotDate(timestamp: String) -> Date? {
            let date = Self.dateFromTimestamp(timestamp)
            if date == nil, !warnedAboutUnparsedTimestamp {
                warnedAboutUnparsedTimestamp = true
                self.log.warning(
                    "Codex cost usage could not parse parent token snapshot timestamp; "
                        + "falling back to lexical comparison",
                    metadata: ["path": fileURL.path, "timestamp": timestamp])
            }
            return date
        }

        func appendSnapshot(timestamp: String, last: CostUsageCodexTotals?, total: CostUsageCodexTotals?) {
            guard last != nil || total != nil else { return }
            let counted = accumulator.apply(last: last, total: total)
            snapshots.append(CodexTimestampedTotals(
                timestamp: timestamp,
                date: parsedSnapshotDate(timestamp: timestamp),
                totals: counted))
        }

        do {
            _ = try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        switch fastLine {
                        case let .sessionMeta(metadata):
                            if sessionId == nil {
                                sessionId = metadata.sessionId
                            }
                        case let .tokenCount(record):
                            appendSnapshot(timestamp: record.timestamp, last: record.last, total: record.total)
                        case .turnContext, .interAgentCommunication, .taskStarted:
                            break
                        }
                        return
                    }

                    autoreleasepool {
                        guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
                        else { return }

                        if obj["type"] as? String == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            return
                        }

                        guard obj["type"] as? String == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        guard payload["type"] as? String == "token_count" else { return }
                        guard let info = payload["info"] as? [String: Any] else { return }
                        guard let timestamp = obj["timestamp"] as? String else { return }

                        func toInt(_ value: Any?) -> Int {
                            if let number = value as? NSNumber {
                                return number.intValue
                            }
                            return 0
                        }

                        let total = (info["total_token_usage"] as? [String: Any]).map {
                            let output = toInt($0["output_tokens"])
                            return CostUsageCodexTotals(
                                input: toInt($0["input_tokens"]),
                                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                                output: output,
                                reasoning: ($0["reasoning_output_tokens"] as? NSNumber)
                                    .map { min(max(0, $0.intValue), max(0, output)) })
                        }
                        let last = (info["last_token_usage"] as? [String: Any]).map {
                            let output = max(0, toInt($0["output_tokens"]))
                            return CostUsageCodexTotals(
                                input: max(0, toInt($0["input_tokens"])),
                                cached: max(0, toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"])),
                                output: output,
                                reasoning: ($0["reasoning_output_tokens"] as? NSNumber)
                                    .map { min(max(0, $0.intValue), output) })
                        }
                        appendSnapshot(timestamp: timestamp, last: last, total: total)
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning parent token snapshots",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
        }

        return (sessionId, snapshots)
    }

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        initialCodexUsageRowIndex: Int = 0,
        inheritedTotalsResolver: ((String, String) -> CodexForkBaseline)? = nil) -> CodexParseResult
    {
        let throwingResolver: ((String, String) throws -> CodexForkBaseline)? = inheritedTotalsResolver
            .map { resolver in
                { sessionId, timestamp in resolver(sessionId, timestamp) }
            }
        return (
            try? Self.parseCodexFileCancellable(
                fileURL: fileURL,
                range: range,
                startOffset: startOffset,
                initialModel: initialModel,
                initialTotals: initialTotals,
                initialRawTotalsBaseline: initialRawTotalsBaseline,
                initialHasDivergentTotals: initialHasDivergentTotals,
                initialCodexTurnID: initialCodexTurnID,
                initialCodexUsageRowIndex: initialCodexUsageRowIndex,
                inheritedTotalsResolver: throwingResolver,
                checkCancellation: nil)) ?? CodexParseResult(
            days: [:],
            parsedBytes: startOffset,
            lastModel: initialModel,
            lastTotals: initialTotals,
            lastCountedTotals: initialTotals,
            lastRawTotalsBaseline: initialRawTotalsBaseline,
            lastRawTotalsWatermark: initialRawTotalsBaseline,
            seenRawTotals: [],
            hasDivergentTotals: initialHasDivergentTotals,
            hasInterleavedTotals: false,
            lastCodexTurnID: initialCodexTurnID,
            sessionId: nil,
            forkedFromId: nil,
            forkTimestamp: nil,
            dependsOnParentTotals: false,
            projectPath: nil,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: nil,
                forkedFromId: nil,
                cwd: nil,
                title: nil,
                startedAtUnixMs: nil,
                latestActivityUnixMs: nil),
            rows: [],
            nextUsageRowIndex: initialCodexUsageRowIndex,
            tokenSnapshots: [],
            jsonlResumeState: nil,
            bufferedSubagentLines: nil,
            subagentResumeState: nil,
            deferredReplayState: nil,
            bufferedUnresolvedForkLines: nil,
            forkAccountingState: nil)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseCodexFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialRawTotalsWatermark: CostUsageCodexTotals? = nil,
        initialSeenRawTotals: [CostUsageCodexTotals] = [],
        initialHasDivergentTotals: Bool = false,
        initialHasInterleavedTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        initialCodexUsageRowIndex: Int = 0,
        initialBufferedSubagentLines: [CodexBufferedFastLine]? = nil,
        initialBufferedUnresolvedForkLines: [CodexBufferedFastLine]? = nil,
        initialOrdinaryForkContext: CodexOrdinaryForkResumeContext? = nil,
        initialOrdinalSubagentContext: CodexOrdinalSubagentResumeContext? = nil,
        initialDeferredReplayContext: CodexDeferredReplayContext? = nil,
        initialJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        maxBytesToRead: Int64? = nil,
        shouldStopReading: ((Int64) -> Bool)? = nil,
        inheritedTotalsResolver: ((String, String) throws -> CodexForkBaseline)? = nil,
        checkCancellation: CancellationCheck? = nil) throws -> CodexParseResult
    {
        let restartsDeferredIndexingFromByteZero = initialDeferredReplayContext?.state
            .restartIndexingFromByteZero == true
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId = restartsDeferredIndexingFromByteZero ? nil : (
            initialDeferredReplayContext?.sessionId
                ?? initialOrdinalSubagentContext?.sessionId
                ?? initialOrdinaryForkContext?.sessionId)
        var forkedFromId = restartsDeferredIndexingFromByteZero ? nil : (
            initialOrdinalSubagentContext?.parentSessionId
                ?? initialDeferredReplayContext?.parentSessionId
                ?? initialOrdinaryForkContext?.parentSessionId)
        var projectPath = restartsDeferredIndexingFromByteZero ? nil : (
            initialDeferredReplayContext?.projectPath
                ?? initialOrdinalSubagentContext?.projectPath
                ?? initialOrdinaryForkContext?.projectPath)
        var deferredReplayState = initialDeferredReplayContext?.state
        let deferredReplayIsSubagent = deferredReplayState.map { $0.mode != .unresolvedFork } ?? false
        var isSubagentThread = initialOrdinalSubagentContext != nil || deferredReplayIsSubagent
        var didCaptureLeafMetadata = initialOrdinaryForkContext != nil
            || initialOrdinalSubagentContext != nil
            || (initialDeferredReplayContext != nil && !restartsDeferredIndexingFromByteZero)
        var forkTimestamp = restartsDeferredIndexingFromByteZero ? nil : (
            initialDeferredReplayContext?.forkTimestamp
                ?? initialOrdinalSubagentContext?.forkTimestamp
                ?? initialOrdinaryForkContext?.forkTimestamp)
        var subagentResumeState = initialOrdinalSubagentContext?.state
        var subagentHistoryStartOrdinal = subagentResumeState?.historyStartOrdinal
        var subagentCounterSemantics: CodexSubagentCounterSemantics? = switch deferredReplayState?.mode {
        case .some(.independentSubagent): .independent
        case .some(.localSubagentSuffix), .some(.inheritedSubagentFork),
             .some(.parentConfirmedSubagentCandidate): .copiedPrefix
        case .some(.unresolvedFork), .some(.legacySubagentClassification), .none:
            initialOrdinalSubagentContext == nil ? nil : .copiedPrefix
        }
        var usesLocalSubagentBoundary = initialOrdinalSubagentContext != nil
            || deferredReplayState?.mode == .localSubagentSuffix
        var candidateBoundaryDependsOnParentTotals = false
        var parentConfirmedLocalBoundary = false
        var suppressUnownedCopiedPrefix = false
        var codexSession = restartsDeferredIndexingFromByteZero
            ? CostUsageCodexSessionMetadata(
                sessionId: nil,
                forkedFromId: nil,
                cwd: nil,
                title: nil,
                startedAtUnixMs: nil,
                latestActivityUnixMs: nil)
            : (initialDeferredReplayContext?.codexSession
                ?? initialOrdinalSubagentContext?.codexSession
                ?? initialOrdinaryForkContext?.codexSession
                ?? CostUsageCodexSessionMetadata(
                    sessionId: nil,
                    forkedFromId: nil,
                    cwd: nil,
                    title: nil,
                    startedAtUnixMs: nil,
                    latestActivityUnixMs: nil))
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?
        var forkBaselineResolved = false
        var hasUnresolvedForkBaseline = false
        var currentTurnID = initialCodexTurnID
        var codexUsageRowIndex = initialCodexUsageRowIndex
        let deferredLocalBaseline = deferredReplayState?.mode == .localSubagentSuffix
            ? deferredReplayState?.rawTotalsBaseline
            : nil
        var rawTotalsBaseline = initialRawTotalsBaseline ?? initialTotals ?? deferredLocalBaseline
        var sawDivergentTotals = initialHasDivergentTotals
        var tracker = CodexTotalsTracker(
            watermark: initialRawTotalsWatermark ?? initialRawTotalsBaseline ?? initialTotals ?? deferredLocalBaseline,
            seenRawTotals: initialSeenRawTotals,
            sawInterleavedTotals: initialHasInterleavedTotals)
        var deferredError: Error?

        var days: [String: [String: [Int]]] = [:]
        var rows: [CodexUsageRow] = []
        var tokenSnapshots: [CostUsageCodexTokenSnapshot] = []

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)

            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + input
            packed[1] = (packed[safe: 1] ?? 0) + cached
            packed[2] = (packed[safe: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func sanitizedString(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func unixMilliseconds(from timestamp: String?) -> Int64? {
            guard let timestamp,
                  let date = Self.dateFromTimestamp(timestamp)
            else { return nil }
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }

        func observeTimestamp(_ timestamp: String?) {
            guard let unixMs = unixMilliseconds(from: timestamp) else { return }
            codexSession.startedAtUnixMs = switch codexSession.startedAtUnixMs {
            case let current?: min(current, unixMs)
            case nil: unixMs
            }
            codexSession.latestActivityUnixMs = switch codexSession.latestActivityUnixMs {
            case let current?: max(current, unixMs)
            case nil: unixMs
            }
        }

        func observeCwd(_ value: String?) {
            guard let value = sanitizedString(value) else { return }
            codexSession.cwd = value
        }

        func observeTitle(_ value: String?) {
            guard let value = sanitizedString(value) else { return }
            codexSession.title = value
        }

        func resolveForkBaseline(parentSessionId: String, forkedAt: String) throws {
            guard !forkBaselineResolved else { return }
            guard let inheritedTotalsResolver else { return }
            forkBaselineResolved = true
            switch try inheritedTotalsResolver(parentSessionId, forkedAt) {
            case let .resolved(totals):
                inheritedTotals = totals
                if let initialOrdinaryForkContext {
                    remainingInheritedTotals = initialOrdinaryForkContext.accountingState.remainingInheritedTotals
                } else {
                    remainingInheritedTotals = totals
                }
                hasUnresolvedForkBaseline = false
            case .unresolved:
                hasUnresolvedForkBaseline = true
            }
        }

        func configureForkAccountingIfReady() throws {
            guard let forkedFromId else { return }
            if isSubagentThread, subagentCounterSemantics == nil {
                return
            }
            if subagentCounterSemantics == .independent || usesLocalSubagentBoundary {
                forkBaselineResolved = true
                inheritedTotals = nil
                remainingInheritedTotals = nil
                hasUnresolvedForkBaseline = false
                return
            }
            try resolveForkBaseline(
                parentSessionId: forkedFromId,
                forkedAt: forkTimestamp ?? "")
        }

        func activateExplicitSubagentBoundary(_ historyStartOrdinal: Int?) {
            guard let historyStartOrdinal, historyStartOrdinal >= 0 else { return }
            subagentHistoryStartOrdinal = historyStartOrdinal
            subagentCounterSemantics = .copiedPrefix
            usesLocalSubagentBoundary = true
            isSubagentThread = true
            if subagentResumeState?.historyStartOrdinal != historyStartOrdinal {
                subagentResumeState = CostUsageCodexSubagentResumeState(
                    historyStartOrdinal: historyStartOrdinal,
                    phase: .copiedPrefix,
                    copiedPrefixAccumulatorState: nil)
            }
        }

        func handleSessionMetadata(_ metadata: CodexSessionMetadata) throws {
            // The first parsed session_meta is the authoritative leaf. Copied prefixes can
            // contain many embedded ancestor metas; they are shape evidence, never new identity.
            if didCaptureLeafMetadata {
                // A same-leaf restart may add metadata that was absent from the initial record.
                // Enrich missing fork/project fields without allowing an ancestor to replace identity.
                guard CodexSubagentRolloutShape.sameConcreteSessionID(metadata.sessionId, sessionId) else { return }
                if forkedFromId == nil, let enrichedParentID = metadata.forkedFromId {
                    forkedFromId = enrichedParentID
                    codexSession.forkedFromId = enrichedParentID
                    forkTimestamp = metadata.forkTimestamp ?? forkTimestamp
                    try configureForkAccountingIfReady()
                }
                if projectPath == nil {
                    projectPath = metadata.projectPath
                }
                if subagentHistoryStartOrdinal == nil {
                    subagentHistoryStartOrdinal = metadata.subagentHistoryStartOrdinal
                }
                activateExplicitSubagentBoundary(metadata.subagentHistoryStartOrdinal)
                observeTimestamp(metadata.forkTimestamp)
                if codexSession.cwd == nil {
                    observeCwd(metadata.projectPath)
                }
                return
            }
            didCaptureLeafMetadata = true
            sessionId = metadata.sessionId
            forkedFromId = metadata.forkedFromId
            forkTimestamp = metadata.forkTimestamp
            projectPath = metadata.projectPath
            subagentHistoryStartOrdinal = metadata.subagentHistoryStartOrdinal
            codexSession.sessionId = metadata.sessionId
            codexSession.forkedFromId = metadata.forkedFromId
            observeTimestamp(metadata.forkTimestamp)
            observeCwd(metadata.projectPath)
            isSubagentThread = metadata.isSubagentThread
            activateExplicitSubagentBoundary(metadata.subagentHistoryStartOrdinal)
            try configureForkAccountingIfReady()
        }

        // swiftlint:disable:next function_body_length
        func handleTokenCount(_ record: CodexTokenCountRecord) throws {
            observeTimestamp(record.timestamp)
            guard let dayKey = Self.dayKeyFromTimestamp(record.timestamp, calendar: range.calendar)
                ?? Self.dayKeyFromParsedISO(record.timestamp, calendar: range.calendar)
            else { return }
            guard !suppressUnownedCopiedPrefix else { return }
            // Overflow indexing is intentionally accounting-free. It publishes only a validated
            // raw/token cursor; usage is emitted by the single classified replay afterwards.
            guard deferredReplayState?.phase != .indexing else { return }
            guard deferredReplayState?.mode != .legacySubagentClassification,
                  deferredReplayState?.mode != .parentConfirmedSubagentCandidate
            else { return }

            let model = Self.codexModelEvidence(currentModel)
                ?? Self.codexModelEvidence(record.model)
                ?? CostUsagePricing.codexUnattributedModel
            let total = record.total
            let last = record.last
            // A cumulative fork counter is not attributable until either the parent snapshot or
            // a trustworthy child-owned suffix establishes the inherited baseline. Publishing
            // best-effort `last` rows here can replay billions of copied-prefix tokens.
            guard !hasUnresolvedForkBaseline else { return }

            var deltaInput = 0
            var deltaCached = 0
            var deltaOutput = 0
            var deltaReasoning: Int?

            func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                guard var remaining = remainingInheritedTotals else { return rawDelta }

                let adjusted = CostUsageCodexTotals(
                    input: max(0, rawDelta.input - remaining.input),
                    cached: max(0, rawDelta.cached - remaining.cached),
                    output: max(0, rawDelta.output - remaining.output),
                    reasoning: Self.codexSubtractOptional(rawDelta.reasoning, remaining.reasoning))

                remaining.input = max(0, remaining.input - rawDelta.input)
                remaining.cached = max(0, remaining.cached - rawDelta.cached)
                remaining.output = max(0, remaining.output - rawDelta.output)
                remaining.reasoning = Self.codexSubtractOptional(remaining.reasoning, rawDelta.reasoning)
                remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                              remaining.output == 0
                {
                    nil
                } else {
                    remaining
                }

                return adjusted
            }

            // Fork totals are normalized against the selected baseline. Classified independent
            // counters and locally delimited suffixes intentionally bypass the parent baseline.
            let adjustedTotal: CostUsageCodexTotals? = total.map { rawTotals in
                guard let inheritedTotals, !hasUnresolvedForkBaseline else { return rawTotals }
                return CostUsageCodexTotals(
                    input: max(0, rawTotals.input - inheritedTotals.input),
                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                    output: max(0, rawTotals.output - inheritedTotals.output),
                    reasoning: Self.codexSubtractOptional(rawTotals.reasoning, inheritedTotals.reasoning))
            }

            if let adjustedTotal {
                // Only committed observations enter the seen set. Replacing this with a bare
                // watermark-equality check would skip first-time fork baseline bookkeeping.
                // Post-latch containment remains the load-bearing overcount guard.
                if tracker.isSeen(adjustedTotal) {
                    return
                }
                tracker.latchIfBelowWatermark(adjustedTotal)
            }
            let watermarkBaseline = tracker.watermark ?? rawTotalsBaseline
            defer {
                if let adjustedTotal {
                    tracker.commitObserved(adjustedTotal)
                }
            }

            func totalsDerivedDelta(to currentTotals: CostUsageCodexTotals) -> CostUsageCodexTotals {
                if tracker.sawInterleavedTotals {
                    return Self.codexContainedTotalDelta(
                        watermark: watermarkBaseline,
                        counted: previousTotals,
                        current: currentTotals)
                }
                if sawDivergentTotals {
                    return Self.codexDivergentTotalDelta(
                        rawBaseline: watermarkBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotals)
                }
                return Self.codexTotalDelta(from: watermarkBaseline, to: currentTotals)
            }

            func commitDelta(_ delta: CostUsageCodexTotals, rawBaseline: CostUsageCodexTotals) {
                deltaInput = delta.input
                deltaCached = delta.cached
                deltaOutput = delta.output
                deltaReasoning = delta.reasoning
                let prev = previousTotals ?? .init(
                    input: 0,
                    cached: 0,
                    output: 0,
                    reasoning: delta.reasoning == nil ? nil : 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = rawBaseline
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
            }

            if let currentTotals = adjustedTotal,
               forkedFromId != nil,
               !hasUnresolvedForkBaseline
            {
                // Non-interleaved forks keep totals-only accounting (#1164 / 45b68c34).
                // After latch, use post-latch containment capped by last when present.
                let delta: CostUsageCodexTotals = if tracker.sawInterleavedTotals {
                    Self.codexPostLatchEventDelta(
                        watermark: watermarkBaseline,
                        counted: previousTotals,
                        current: currentTotals,
                        adjustedLast: last.map { adjustedLastDelta($0) })
                } else {
                    totalsDerivedDelta(to: currentTotals)
                }
                commitDelta(delta, rawBaseline: currentTotals)
                remainingInheritedTotals = nil
            } else if let last {
                let rawDelta = last
                let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                var adjustedDelta = adjustedLastDelta(rawDelta)
                let prev = previousTotals ?? .init(
                    input: 0,
                    cached: 0,
                    output: 0,
                    reasoning: adjustedDelta.reasoning == nil ? nil : 0)

                if let currentTotals = adjustedTotal, !hasUnresolvedForkBaseline {
                    if tracker.sawInterleavedTotals {
                        adjustedDelta = Self.codexPostLatchEventDelta(
                            watermark: watermarkBaseline,
                            counted: previousTotals,
                            current: currentTotals,
                            adjustedLast: adjustedDelta)
                        remainingInheritedTotals = nil
                    } else {
                        let totalDelta = Self.codexTotalDelta(from: watermarkBaseline, to: currentTotals)
                        if !hadRemainingInheritedTotals,
                           Self.codexShouldPreferTotalDelta(
                               rawBaseline: watermarkBaseline,
                               currentTotal: currentTotals,
                               totalDelta: totalDelta,
                               lastDelta: rawDelta,
                               sawDivergentTotals: sawDivergentTotals)
                        {
                            adjustedDelta = totalDelta
                            remainingInheritedTotals = nil
                        }
                    }
                    commitDelta(adjustedDelta, rawBaseline: currentTotals)
                } else {
                    let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                    deltaInput = adjustedDelta.input
                    deltaCached = adjustedDelta.cached
                    deltaOutput = adjustedDelta.output
                    deltaReasoning = adjustedDelta.reasoning
                    previousTotals = countedTotals
                    rawTotalsBaseline = countedTotals
                    tracker.raiseWatermark(to: countedTotals)
                }
            } else if let currentTotals = adjustedTotal {
                commitDelta(totalsDerivedDelta(to: currentTotals), rawBaseline: currentTotals)
                remainingInheritedTotals = nil
            } else {
                return
            }

            if deltaInput == 0, deltaCached == 0, deltaOutput == 0 {
                return
            }
            let eventIndex = codexUsageRowIndex
            codexUsageRowIndex += 1
            let normModel = CostUsagePricing.normalizeCodexModel(model)
            add(
                dayKey: dayKey,
                model: normModel,
                input: deltaInput,
                cached: deltaCached,
                output: deltaOutput)
            let usageRow = CodexUsageRow(
                day: dayKey,
                model: normModel,
                rawModel: model,
                turnID: record.turnID ?? currentTurnID,
                eventIndex: eventIndex,
                timestampUnixMs: unixMilliseconds(from: record.timestamp),
                input: deltaInput,
                cached: deltaCached,
                output: deltaOutput,
                reasoning: deltaReasoning)
            if CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            {
                rows.append(usageRow)
            }
        }

        func processFastLine(_ fastLine: CodexFastLine) throws {
            switch fastLine {
            case let .sessionMeta(metadata):
                try handleSessionMetadata(metadata)
            case let .turnContext(metadata):
                observeTimestamp(metadata.timestamp)
                observeCwd(metadata.cwd)
                observeTitle(metadata.title)
                if let model = metadata.model {
                    // An explicitly blank context clears stale model evidence; an omitted field preserves it.
                    currentModel = sanitizedString(model)
                }
            case .interAgentCommunication:
                break
            case let .taskStarted(turnID):
                currentTurnID = turnID
            case let .tokenCount(record):
                try handleTokenCount(record)
            }
        }

        if initialOrdinaryForkContext != nil || initialOrdinalSubagentContext != nil {
            try configureForkAccountingIfReady()
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        var pendingSubagentLines = initialBufferedSubagentLines
        var bufferedUnresolvedForkLines = initialBufferedUnresolvedForkLines
        var legacySubagentShape = deferredReplayState?.legacySubagentShape
        var unresolvedForkBufferedBytes = initialBufferedUnresolvedForkLines?.reduce(into: 0) {
            $0 += Self.codexBufferedFastLineApproximateBytes($1)
        } ?? 0

        if let initialBufferedSubagentLines, startOffset > 0 {
            for buffered in initialBufferedSubagentLines {
                guard case let .sessionMeta(metadata) = buffered.line else { continue }
                try handleSessionMetadata(metadata)
            }
        } else if startOffset == 0,
                  let metadata = try Self.parseCodexSessionMetadata(
                      fileURL: fileURL,
                      checkCancellation: checkCancellation)
        {
            try handleSessionMetadata(metadata)
            if metadata.isSubagentThread {
                // Subagent provenance can omit a fork id. Buffer parsed events, not JSON, so
                // classification remains one disk pass and reuses the existing totals reducer.
                // Protocol-delimited rollouts are already authoritative and use the constant-size
                // ordinal state instead of retaining their copied prefix.
                if subagentResumeState == nil, deferredReplayState == nil {
                    pendingSubagentLines = []
                    legacySubagentShape = Self.initialLegacySubagentShapeState(
                        leafSessionId: metadata.sessionId)
                }
            }
        }
        if legacySubagentShape == nil, let initialBufferedSubagentLines {
            // Restore the authoritative leaf identity before replaying the buffered prefix into
            // the streaming shape classifier. Rebuilding the shape first leaves `sessionId` nil
            // on a bounded resume, so its opening leaf `session_meta` is mistaken for an embedded
            // ancestor and the completed index can infer the leaf itself as `forkedFromId`.
            var rebuilt = Self.initialLegacySubagentShapeState(
                leafSessionId: sessionId)
            for buffered in initialBufferedSubagentLines {
                rebuilt.bufferedApproximateBytes += Self.codexBufferedFastLineApproximateBytes(buffered)
                Self.observeLegacySubagentShape(
                    buffered,
                    hasExplicitParent: forkedFromId != nil,
                    state: &rebuilt)
            }
            legacySubagentShape = rebuilt
        }
        if let initialBufferedUnresolvedForkLines, startOffset > 0 {
            for buffered in initialBufferedUnresolvedForkLines {
                guard case let .sessionMeta(metadata) = buffered.line else { continue }
                try handleSessionMetadata(metadata)
            }
            if !hasUnresolvedForkBaseline {
                for buffered in initialBufferedUnresolvedForkLines {
                    try processFastLine(buffered.line)
                }
                bufferedUnresolvedForkLines = nil
            }
        }

        func resetForOwnedSubagentSuffix(rawTotalsBaseline ownedBaseline: CostUsageCodexTotals?) throws {
            guard var state = subagentResumeState else { return }
            state.phase = ownedBaseline == nil ? .awaitingOwnedBaseline : .ownedSuffix
            state.copiedPrefixAccumulatorState = nil
            subagentResumeState = state
            subagentCounterSemantics = .copiedPrefix
            usesLocalSubagentBoundary = true
            previousTotals = nil
            rawTotalsBaseline = ownedBaseline
            sawDivergentTotals = false
            tracker = CodexTotalsTracker(
                watermark: ownedBaseline,
                seenRawTotals: [],
                sawInterleavedTotals: false)
            currentModel = nil
            currentTurnID = nil
            try configureForkAccountingIfReady()
        }

        func inferredOwnedSubagentBaseline(_ record: CodexTokenCountRecord) -> CostUsageCodexTotals {
            if let total = record.total, let last = record.last,
               Self.codexTotalsAtLeast(total, last)
            {
                return Self.codexTotalDelta(from: last, to: total)
            }
            // An explicit ordinal proves that every observable token event before this point was
            // copied history. With no usable prefix total, a last-only or total-only first owned
            // event starts from zero; retaining it would only defer a baseline the file cannot
            // establish later and would make the buffer grow without bound.
            return .init(input: 0, cached: 0, output: 0)
        }

        func establishAwaitingOwnedSubagentBaseline(_ baseline: CostUsageCodexTotals) throws {
            guard var state = subagentResumeState else { return }
            state.phase = .ownedSuffix
            state.copiedPrefixAccumulatorState = nil
            subagentResumeState = state
            previousTotals = nil
            rawTotalsBaseline = baseline
            sawDivergentTotals = false
            tracker = CodexTotalsTracker(
                watermark: baseline,
                seenRawTotals: [],
                sawInterleavedTotals: false)
            // Keep model/turn context observed after the ordinal boundary and before this first
            // token event. It belongs to the owned suffix and must survive bounded-slice resumes.
            try configureForkAccountingIfReady()
        }

        func prepareDeferredReplayIfNeeded() throws {
            guard var state = deferredReplayState, state.phase == .replaying else { return }
            switch state.mode {
            case .localSubagentSuffix:
                subagentCounterSemantics = .copiedPrefix
                usesLocalSubagentBoundary = true
                forkBaselineResolved = forkedFromId != nil
                inheritedTotals = nil
                remainingInheritedTotals = nil
                hasUnresolvedForkBaseline = false

            case .independentSubagent:
                subagentCounterSemantics = .independent
                usesLocalSubagentBoundary = false
                try configureForkAccountingIfReady()

            case .inheritedSubagentFork, .unresolvedFork:
                subagentCounterSemantics = state.mode == .inheritedSubagentFork ? .copiedPrefix : nil
                usesLocalSubagentBoundary = false
                guard let parentSessionId = forkedFromId else {
                    hasUnresolvedForkBaseline = true
                    return
                }
                try resolveForkBaseline(
                    parentSessionId: parentSessionId,
                    forkedAt: forkTimestamp ?? "")

            case .parentConfirmedSubagentCandidate:
                guard let parentSessionId = forkedFromId,
                      let inheritedTotalsResolver
                else {
                    hasUnresolvedForkBaseline = true
                    return
                }
                switch try inheritedTotalsResolver(parentSessionId, forkTimestamp ?? "") {
                case let .resolved(parentTotals):
                    if Self.codexTotalsEqual(parentTotals, state.parentTotalsAtBoundary) {
                        state.mode = .localSubagentSuffix
                        subagentCounterSemantics = .copiedPrefix
                        usesLocalSubagentBoundary = true
                        rawTotalsBaseline = state.rawTotalsBaseline
                        tracker = CodexTotalsTracker(
                            watermark: state.rawTotalsBaseline,
                            seenRawTotals: [],
                            sawInterleavedTotals: false)
                        forkBaselineResolved = true
                        inheritedTotals = nil
                        remainingInheritedTotals = nil
                        hasUnresolvedForkBaseline = false
                    } else {
                        state.mode = .independentSubagent
                        subagentCounterSemantics = .independent
                        usesLocalSubagentBoundary = false
                        forkBaselineResolved = true
                        inheritedTotals = nil
                        remainingInheritedTotals = nil
                        hasUnresolvedForkBaseline = false
                    }
                    deferredReplayState = state
                case .unresolved:
                    hasUnresolvedForkBaseline = true
                }

            case .legacySubagentClassification:
                // Classification is completed at the indexing EOF before replay can begin.
                hasUnresolvedForkBaseline = true
            }
        }

        try prepareDeferredReplayIfNeeded()

        func routeExplicitSubagentLine(
            _ fastLine: CodexFastLine,
            ordinal: Int?) throws
        {
            while true {
                guard var state = subagentResumeState else {
                    try processFastLine(fastLine)
                    return
                }
                switch state.phase {
                case .copiedPrefix:
                    guard let ordinal, ordinal >= state.historyStartOrdinal else {
                        if case let .tokenCount(record) = fastLine,
                           record.last != nil || record.total != nil
                        {
                            var accumulator = CodexSnapshotAccumulator(
                                state: state.copiedPrefixAccumulatorState)
                            _ = accumulator.apply(last: record.last, total: record.total)
                            state.copiedPrefixAccumulatorState = accumulator.state
                            subagentResumeState = state
                        } else if case .sessionMeta = fastLine {
                            // Same-leaf metadata can enrich lineage/project fields. Embedded ancestor
                            // metadata is rejected by `handleSessionMetadata` and remains copied data.
                            try processFastLine(fastLine)
                        }
                        return
                    }

                    let prefixBaseline = state.copiedPrefixAccumulatorState?.rawTotalsBaseline
                        ?? state.copiedPrefixAccumulatorState?.countedTotals
                    try resetForOwnedSubagentSuffix(rawTotalsBaseline: prefixBaseline)
                    // Reset changes the phase to awaitingOwnedBaseline/ownedSuffix. Re-read that
                    // state in this frame instead of recursively stacking the boundary record.
                    continue

                case .awaitingOwnedBaseline:
                    if case let .tokenCount(record) = fastLine {
                        try establishAwaitingOwnedSubagentBaseline(
                            inferredOwnedSubagentBaseline(record))
                    }
                    try processFastLine(fastLine)
                    return

                case .ownedSuffix:
                    try processFastLine(fastLine)
                    return
                }
            }
        }

        func routeFastLine(
            _ fastLine: CodexFastLine,
            lineIndex: Int,
            ordinal: Int?,
            startOffset: Int64,
            endOffset: Int64) throws
        {
            let bufferedLine = Self.CodexBufferedFastLine(
                lineIndex: lineIndex,
                ordinal: ordinal,
                startOffset: startOffset,
                endOffset: endOffset,
                line: fastLine)
            if case let .tokenCount(record) = fastLine, record.last != nil || record.total != nil {
                tokenSnapshots.append(CostUsageCodexTokenSnapshot(
                    timestamp: record.timestamp,
                    last: record.last,
                    total: record.total,
                    endOffset: endOffset))
            }
            if var deferred = deferredReplayState {
                switch deferred.phase {
                case .indexing:
                    if deferred.mode == .legacySubagentClassification {
                        var shape = deferred.legacySubagentShape
                            ?? Self.initialLegacySubagentShapeState(leafSessionId: sessionId)
                        if deferred.restartIndexingFromByteZero == true,
                           !shape.observedAuthoritativeMetadata,
                           case let .sessionMeta(metadata) = fastLine
                        {
                            shape.leafSessionId = Self.normalizedBoundedCodexSessionID(metadata.sessionId)
                        }
                        Self.observeLegacySubagentShape(
                            bufferedLine,
                            hasExplicitParent: forkedFromId != nil,
                            state: &shape)
                        deferred.legacySubagentShape = shape
                        deferredReplayState = deferred
                        // Keep the ordinary session projection current while indexing. The token
                        // handler's indexing guard suppresses usage rows, but timestamps, cwd,
                        // title, model, and turn context must survive the copied-history/no-owned-
                        // suffix case, which intentionally needs no second pass.
                        try processFastLine(fastLine)
                    } else {
                        // Ordinary unresolved forks still collect metadata/model state, but the
                        // indexing guard in `handleTokenCount` prevents any usage publication.
                        try processFastLine(fastLine)
                    }
                    return

                case .replaying:
                    if deferred.mode == .legacySubagentClassification
                        || deferred.mode == .parentConfirmedSubagentCandidate
                    {
                        // Fail closed if classification/dependency preparation did not converge.
                        return
                    }
                    if deferred.mode == .localSubagentSuffix,
                       let ownedStartOffset = deferred.ownedSuffixStartOffset,
                       startOffset < ownedStartOffset
                    {
                        return
                    }
                    try processFastLine(fastLine)
                    return
                }
            } else if subagentResumeState != nil {
                try routeExplicitSubagentLine(fastLine, ordinal: ordinal)
            } else if pendingSubagentLines != nil {
                var shape = legacySubagentShape
                    ?? Self.initialLegacySubagentShapeState(leafSessionId: sessionId)
                Self.observeLegacySubagentShape(
                    bufferedLine,
                    hasExplicitParent: forkedFromId != nil,
                    state: &shape)
                let nextBytes = shape.bufferedApproximateBytes
                    + Self.codexBufferedFastLineApproximateBytes(bufferedLine)
                shape.bufferedApproximateBytes = nextBytes
                legacySubagentShape = shape
                if (pendingSubagentLines?.count ?? 0) >= Self.codexBufferedFastLineCountLimit
                    || nextBytes > Self.codexBufferedFastLineByteLimit
                {
                    // Never classify or account from a truncated prefix. Finish indexing with
                    // constant state, then perform one classified sequential replay.
                    pendingSubagentLines = nil
                    deferredReplayState = CostUsageCodexDeferredReplayState(
                        phase: .indexing,
                        mode: .legacySubagentClassification,
                        ownedSuffixStartOffset: nil,
                        rawTotalsBaseline: nil,
                        parentTotalsAtBoundary: nil,
                        legacySubagentShape: shape)
                } else {
                    pendingSubagentLines?.append(bufferedLine)
                }
            } else {
                try processFastLine(fastLine)
                if hasUnresolvedForkBaseline {
                    if bufferedUnresolvedForkLines == nil {
                        bufferedUnresolvedForkLines = []
                    }
                    let nextBytes = unresolvedForkBufferedBytes
                        + Self.codexBufferedFastLineApproximateBytes(bufferedLine)
                    if (bufferedUnresolvedForkLines?.count ?? 0) >= Self.codexBufferedFastLineCountLimit
                        || nextBytes > Self.codexBufferedFastLineByteLimit
                    {
                        bufferedUnresolvedForkLines = nil
                        unresolvedForkBufferedBytes = 0
                        deferredReplayState = CostUsageCodexDeferredReplayState(
                            phase: .indexing,
                            mode: .unresolvedFork,
                            ownedSuffixStartOffset: nil,
                            rawTotalsBaseline: nil,
                            parentTotalsAtBoundary: nil,
                            legacySubagentShape: nil)
                    } else {
                        unresolvedForkBufferedBytes = nextBytes
                        bufferedUnresolvedForkLines?.append(bufferedLine)
                    }
                }
            }
        }

        var parsedBytes: Int64
        let targetSize = Self.codexFileMetadata(fileURL: fileURL).size
        var physicalLineIndex = max(
            (initialBufferedSubagentLines?.last?.lineIndex ?? -1) + 1,
            deferredReplayState?.legacySubagentShape?.nextLineIndex ?? 0)
        let startedAsDeferredReplay = deferredReplayState?.phase == .replaying
        var jsonlResumeState = initialJSONLResumeState
        do {
            let scanProgress = try CostUsageJsonl.scanBounded(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                maxBytesToRead: maxBytesToRead,
                resumeState: initialJSONLResumeState,
                shouldStop: shouldStopReading,
                checkCancellation: checkCancellation,
                onLine: { line in
                    let lineIndex = physicalLineIndex
                    physicalLineIndex += 1
                    if deferredError != nil {
                        return
                    }
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // `turn_context` can carry very large prompts, but its model usually appears near the start.
                        // A truncated line cannot be structurally validated with Foundation, so
                        // only accept the canonical root discriminator to avoid prompt-text hits.
                        let truncatedTurnContext = Self.extractCodexTruncatedTurnContext(from: line.bytes)
                        if truncatedTurnContext.isValid {
                            do {
                                try routeFastLine(
                                    .turnContext(CodexTurnContextMetadata(
                                        timestamp: nil,
                                        model: truncatedTurnContext.model,
                                        cwd: nil,
                                        title: nil)),
                                    lineIndex: lineIndex,
                                    ordinal: Self.codexLineOrdinal(line.bytes),
                                    startOffset: line.startOffset,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                        }
                        if pendingSubagentLines != nil
                            || (deferredReplayState?.phase == .indexing
                                && deferredReplayState?.mode == .legacySubagentClassification)
                        {
                            let truncatedMetadata = Self.extractCodexTruncatedSessionMetadata(from: line.bytes)
                            if truncatedMetadata.isSessionMetadata {
                                do {
                                    try routeFastLine(
                                        .sessionMeta(CodexSessionMetadata(
                                            sessionId: truncatedMetadata.sessionID,
                                            forkedFromId: nil,
                                            forkTimestamp: nil,
                                            projectPath: nil,
                                            isSubagentThread: false,
                                            subagentHistoryStartOrdinal: nil)),
                                        lineIndex: lineIndex,
                                        ordinal: Self.codexLineOrdinal(line.bytes),
                                        startOffset: line.startOffset,
                                        endOffset: line.endOffset)
                                } catch {
                                    deferredError = error
                                }
                            }
                        }
                        return
                    }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                        || line.bytes.containsAscii(#""session_meta""#)
                        || line.bytes.containsAscii(#""type":"inter_agent_communication_metadata""#)
                        || line.bytes.containsAscii(#""inter_agent_communication_metadata""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#),
                       !line.bytes.containsAscii(#""token_count""#),
                       !line.bytes.containsAscii(#""task_started""#)
                    {
                        return
                    }

                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        let ordinal = Self.codexLineOrdinal(line.bytes)
                        let timestampValidity = fastLine.requiresValidTimestamp
                            ? Self.codexFastLineTimestampValidity(line.bytes)
                            : true
                        if timestampValidity == true {
                            do {
                                try routeFastLine(
                                    fastLine,
                                    lineIndex: lineIndex,
                                    ordinal: ordinal,
                                    startOffset: line.startOffset,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                            return
                        }
                        if timestampValidity == false {
                            return
                        }
                    }

                    guard let decoded = Self.decodeCodexFoundationFallbackLine(line.bytes)
                    else { return }
                    do {
                        try routeFastLine(
                            decoded.fastLine,
                            lineIndex: lineIndex,
                            ordinal: decoded.ordinal,
                            startOffset: line.startOffset,
                            endOffset: line.endOffset)
                    } catch {
                        deferredError = error
                    }
                })
            parsedBytes = scanProgress.readOffset
            jsonlResumeState = scanProgress.resumeState
            if let deferredError {
                throw deferredError
            }

            if startedAsDeferredReplay,
               parsedBytes > startOffset,
               var replay = deferredReplayState
            {
                replay.replayStarted = true
                deferredReplayState = replay
            }
            if parsedBytes > startOffset,
               var indexing = deferredReplayState,
               indexing.phase == .indexing,
               indexing.restartIndexingFromByteZero == true
            {
                indexing.restartIndexingFromByteZero = false
                deferredReplayState = indexing
            }

            if parsedBytes >= targetSize, jsonlResumeState == nil {
                if startedAsDeferredReplay,
                   !hasUnresolvedForkBaseline,
                   deferredReplayState?.mode != .legacySubagentClassification,
                   deferredReplayState?.mode != .parentConfirmedSubagentCandidate
                {
                    // The classified pass has now consumed every source byte exactly once. A
                    // partial replay retains the plan; EOF retires it permanently.
                    deferredReplayState = nil
                } else if var deferred = deferredReplayState, deferred.phase == .indexing {
                    switch deferred.mode {
                    case .unresolvedFork:
                        deferred.phase = .replaying
                        deferred.legacySubagentShape = nil
                        deferred.replayStarted = false
                        deferredReplayState = deferred

                    case .legacySubagentClassification:
                        let shape = deferred.legacySubagentShape
                            ?? Self.initialLegacySubagentShapeState(leafSessionId: sessionId)
                        if forkedFromId == nil, shape.ancestorSessionIds.count == 1 {
                            forkedFromId = shape.ancestorSessionIds[0]
                            codexSession.forkedFromId = forkedFromId
                        }

                        if shape.hasEmbeddedAncestor {
                            subagentCounterSemantics = .copiedPrefix
                            if let ownedStartOffset = shape.ownedSuffixStartOffset,
                               let ownedBaseline = shape.ownedSuffixBaseline
                            {
                                deferred.phase = .replaying
                                deferred.mode = .localSubagentSuffix
                                deferred.ownedSuffixStartOffset = ownedStartOffset
                                deferred.rawTotalsBaseline = ownedBaseline
                                deferred.parentTotalsAtBoundary = nil
                                deferred.legacySubagentShape = nil
                                deferred.replayStarted = false
                                usesLocalSubagentBoundary = true
                                deferredReplayState = deferred
                            } else if forkedFromId != nil {
                                deferred.phase = .replaying
                                deferred.mode = .inheritedSubagentFork
                                deferred.ownedSuffixStartOffset = nil
                                deferred.rawTotalsBaseline = nil
                                deferred.parentTotalsAtBoundary = nil
                                deferred.legacySubagentShape = nil
                                deferred.replayStarted = false
                                candidateBoundaryDependsOnParentTotals = true
                                deferredReplayState = deferred
                            } else {
                                // Copied history with no owned suffix contributes zero. No second
                                // pass is needed and, critically, no truncated buffer is replayed.
                                suppressUnownedCopiedPrefix = true
                                deferredReplayState = nil
                            }
                        } else if let ownedStartOffset = shape.ownedSuffixStartOffset,
                                  let ownedBaseline = shape.ownedSuffixBaseline,
                                  shape.locallyConfirmedBoundary
                        {
                            subagentCounterSemantics = .copiedPrefix
                            usesLocalSubagentBoundary = true
                            deferred.phase = .replaying
                            deferred.mode = .localSubagentSuffix
                            deferred.ownedSuffixStartOffset = ownedStartOffset
                            deferred.rawTotalsBaseline = ownedBaseline
                            deferred.parentTotalsAtBoundary = nil
                            deferred.legacySubagentShape = nil
                            deferred.replayStarted = false
                            deferredReplayState = deferred
                        } else if let ownedStartOffset = shape.ownedSuffixStartOffset,
                                  let ownedBaseline = shape.ownedSuffixBaseline,
                                  forkedFromId != nil
                        {
                            subagentCounterSemantics = .independent
                            candidateBoundaryDependsOnParentTotals = true
                            deferred.phase = .replaying
                            deferred.mode = .parentConfirmedSubagentCandidate
                            deferred.ownedSuffixStartOffset = ownedStartOffset
                            deferred.rawTotalsBaseline = ownedBaseline
                            deferred.parentTotalsAtBoundary = shape.parentTotalsAtBoundary
                            deferred.legacySubagentShape = nil
                            deferred.replayStarted = false
                            deferredReplayState = deferred
                        } else {
                            subagentCounterSemantics = .independent
                            deferred.phase = .replaying
                            deferred.mode = .independentSubagent
                            deferred.ownedSuffixStartOffset = nil
                            deferred.rawTotalsBaseline = nil
                            deferred.parentTotalsAtBoundary = nil
                            deferred.legacySubagentShape = nil
                            deferred.replayStarted = false
                            deferredReplayState = deferred
                        }

                    case .independentSubagent, .localSubagentSuffix,
                         .parentConfirmedSubagentCandidate, .inheritedSubagentFork:
                        // These are replay-only modes; retaining an indexing phase would be an
                        // invalid cache state. Fail closed and require a classified replay.
                        deferred.phase = .replaying
                        deferred.replayStarted = false
                        deferredReplayState = deferred
                    }
                }
            }

            if let pendingSubagentLines, parsedBytes >= targetSize, jsonlResumeState == nil {
                // Same-leaf metadata can fill lineage fields after the opening record. Collect it
                // before replay so copied-prefix totals never run once on the wrong baseline, and
                // so an owned-suffix filter cannot discard the only fork identifier.
                for buffered in pendingSubagentLines {
                    guard case let .sessionMeta(metadata) = buffered.line,
                          CodexSubagentRolloutShape.sameConcreteSessionID(metadata.sessionId, sessionId)
                    else { continue }
                    if forkedFromId == nil, let enrichedParentID = metadata.forkedFromId {
                        forkedFromId = enrichedParentID
                        codexSession.forkedFromId = enrichedParentID
                        forkTimestamp = metadata.forkTimestamp ?? forkTimestamp
                    }
                    if projectPath == nil {
                        projectPath = metadata.projectPath
                    }
                    if subagentHistoryStartOrdinal == nil {
                        subagentHistoryStartOrdinal = metadata.subagentHistoryStartOrdinal
                    }
                    observeTimestamp(metadata.forkTimestamp)
                    if codexSession.cwd == nil {
                        observeCwd(metadata.projectPath)
                    }
                }
                let observations = pendingSubagentLines.compactMap { buffered -> CodexSubagentRolloutShape
                    .Observation? in
                    let kind: CodexSubagentRolloutShape.Observation.Kind
                    switch buffered.line {
                    case let .sessionMeta(metadata):
                        kind = .sessionMetadata(id: metadata.sessionId)
                    case .turnContext:
                        kind = .turnContext
                    case let .interAgentCommunication(triggerTurn):
                        kind = .interAgentCommunication(triggerTurn: triggerTurn)
                    case let .tokenCount(record):
                        kind = .tokenCount(total: record.total, last: record.last)
                    case .taskStarted:
                        return nil
                    }
                    return Self.CodexSubagentRolloutShape.Observation(
                        lineIndex: buffered.lineIndex,
                        kind: kind)
                }
                let shape = CodexSubagentRolloutShape.classify(
                    leafSessionID: sessionId,
                    observations: observations,
                    hasExplicitParent: forkedFromId != nil)
                subagentCounterSemantics = shape.counterSemantics
                if forkedFromId == nil {
                    forkedFromId = shape.inferredParentSessionID
                }
                let explicitOwnedSuffix: CodexSubagentRolloutShape.CodexSubagentOwnedSuffix? = {
                    guard let startOrdinal = subagentHistoryStartOrdinal,
                          let firstOwnedLine = pendingSubagentLines.first(where: {
                              ($0.ordinal ?? Int.min) >= startOrdinal
                          })
                    else { return nil }

                    let inheritedTotal = pendingSubagentLines
                        .prefix(while: { ($0.ordinal ?? Int.min) < startOrdinal })
                        .compactMap { buffered -> CostUsageCodexTotals? in
                            guard case let .tokenCount(record) = buffered.line else { return nil }
                            return record.total
                        }
                        .last
                    let firstOwnedToken = pendingSubagentLines.first { buffered in
                        guard (buffered.ordinal ?? Int.min) >= startOrdinal,
                              case .tokenCount = buffered.line
                        else { return false }
                        return true
                    }
                    let inferredTotal = firstOwnedToken.flatMap { buffered -> CostUsageCodexTotals? in
                        guard case let .tokenCount(record) = buffered.line else { return nil }
                        if let total = record.total, let last = record.last,
                           Self.codexTotalsAtLeast(total, last)
                        {
                            return Self.codexTotalDelta(from: last, to: total)
                        }
                        if record.total == nil, record.last != nil {
                            return .init(input: 0, cached: 0, output: 0)
                        }
                        return nil
                    }
                    guard let rawTotalsBaseline = inheritedTotal ?? inferredTotal else { return nil }
                    return .init(
                        startLineIndex: firstOwnedLine.lineIndex,
                        rawTotalsBaseline: rawTotalsBaseline)
                }()

                var ownedSuffix = explicitOwnedSuffix ?? shape.ownedSuffix
                var locallyConfirmedBoundary = explicitOwnedSuffix != nil
                if explicitOwnedSuffix != nil {
                    subagentCounterSemantics = .copiedPrefix
                } else if let candidate = shape.ownedSuffixCandidate {
                    if candidate.isLocallyConfirmed {
                        subagentCounterSemantics = .copiedPrefix
                        ownedSuffix = candidate.ownedSuffix
                        locallyConfirmedBoundary = true
                    } else if let parentSessionID = forkedFromId {
                        candidateBoundaryDependsOnParentTotals = true
                        if let inheritedTotalsResolver {
                            switch try inheritedTotalsResolver(parentSessionID, forkTimestamp ?? "") {
                            case let .resolved(parentTotals):
                                if Self.codexTotalsEqual(parentTotals, candidate.parentTotalsAtBoundary) {
                                    subagentCounterSemantics = .copiedPrefix
                                    ownedSuffix = candidate.ownedSuffix
                                    parentConfirmedLocalBoundary = true
                                }
                            case .unresolved:
                                break
                            }
                        }
                    }
                }
                suppressUnownedCopiedPrefix = subagentCounterSemantics == .copiedPrefix
                    && ownedSuffix == nil
                    && forkedFromId == nil
                if let ownedSuffix {
                    usesLocalSubagentBoundary = true
                    previousTotals = nil
                    // Keep totals-derived accounting after the boundary. Real flat-total rows
                    // repeat the previous token payload with a fresh outer timestamp; their
                    // non-zero `last` is replay evidence, not new usage (#2037).
                    rawTotalsBaseline = ownedSuffix.rawTotalsBaseline
                    sawDivergentTotals = false
                    tracker = CodexTotalsTracker(
                        watermark: ownedSuffix.rawTotalsBaseline,
                        seenRawTotals: [],
                        sawInterleavedTotals: false)
                    currentModel = nil
                    currentTurnID = nil
                }
                if let startOrdinal = subagentHistoryStartOrdinal,
                   explicitOwnedSuffix != nil
                {
                    subagentResumeState = CostUsageCodexSubagentResumeState(
                        historyStartOrdinal: startOrdinal,
                        phase: .ownedSuffix,
                        copiedPrefixAccumulatorState: nil)
                }
                self.log.debug(
                    "Codex cost usage classified subagent rollout counter semantics",
                    metadata: [
                        "sessionId": sessionId ?? "unknown",
                        "semantics": subagentCounterSemantics == .copiedPrefix ? "copiedPrefix" : "independent",
                        "localBoundary": ownedSuffix == nil ? "false" : "true",
                        "locallyConfirmedBoundary": locallyConfirmedBoundary ? "true" : "false",
                        "parentConfirmedBoundary": parentConfirmedLocalBoundary ? "true" : "false",
                        "suppressedUnownedPrefix": suppressUnownedCopiedPrefix ? "true" : "false",
                        "sessionMetadataCount": String(observations.count(where: {
                            if case .sessionMetadata = $0.kind {
                                true
                            } else {
                                false
                            }
                        })),
                    ])
                try configureForkAccountingIfReady()
                for buffered in pendingSubagentLines
                    where ownedSuffix.map({ buffered.lineIndex >= $0.startLineIndex }) ?? true
                {
                    try processFastLine(buffered.line)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning session file",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            parsedBytes = startOffset
            jsonlResumeState = initialJSONLResumeState
        }

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals)
                ? nil
                : previousTotals,
            lastCountedTotals: previousTotals,
            lastRawTotalsBaseline: rawTotalsBaseline,
            lastRawTotalsWatermark: tracker.watermark,
            seenRawTotals: tracker.seenRawTotals,
            hasDivergentTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals),
            hasInterleavedTotals: tracker.sawInterleavedTotals,
            lastCodexTurnID: currentTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkTimestamp: forkTimestamp,
            dependsOnParentTotals: forkedFromId != nil
                && (candidateBoundaryDependsOnParentTotals
                    || (subagentCounterSemantics != .independent && !usesLocalSubagentBoundary)),
            projectPath: projectPath,
            codexSession: codexSession,
            rows: rows,
            nextUsageRowIndex: codexUsageRowIndex,
            tokenSnapshots: tokenSnapshots,
            jsonlResumeState: jsonlResumeState,
            bufferedSubagentLines: parsedBytes < targetSize
                || jsonlResumeState != nil
                || hasUnresolvedForkBaseline
                ? pendingSubagentLines
                : nil,
            subagentResumeState: subagentResumeState,
            deferredReplayState: deferredReplayState,
            bufferedUnresolvedForkLines: hasUnresolvedForkBaseline
                && deferredReplayState == nil
                ? bufferedUnresolvedForkLines
                : nil,
            forkAccountingState: forkedFromId != nil && forkBaselineResolved && !hasUnresolvedForkBaseline
                ? CostUsageCodexForkAccountingState(
                    remainingInheritedTotals: remainingInheritedTotals)
                : nil)
    }

    private static func codexTurnID(from payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String ?? payload["turnId"] as? String ?? payload["id"] as? String {
            return turnID
        }
        if let info = payload["info"] as? [String: Any] {
            return info["turn_id"] as? String ?? info["turnId"] as? String ?? info["id"] as? String
        }
        return nil
    }

    private enum CodexForkBodyScanDecision: Equatable {
        case proceed
        case deferred
        case restartFromByteZero
    }

    private enum CodexForkMetadataPreflightResult {
        case scanned(CodexSessionMetadata?)
        case deferredByBudget
        case sourceMutated
    }

    /// Buffered fork metadata can establish session ownership before body work only while the
    /// exact cached source is unchanged, or while a verified prefix remains intact after append.
    /// A same-session atomic replacement must reach the live metadata preflight instead of
    /// inheriting authority from stale cache fields.
    private static func cachedCodexForkMetadataStillMatchesSource(
        cached: CostUsageFileUsage,
        input: CodexFileScanInput) -> Bool
    {
        guard let fileID = cached.codexScanFileId,
              fileID == input.metadata.fileId
        else { return false }
        if cached.size == input.metadata.size,
           cached.mtimeUnixMs == input.metadata.mtimeUnixMs,
           let cachedChangeUnixNs = cached.codexScanChangeUnixNs,
           cachedChangeUnixNs == input.metadata.changeUnixNs
        {
            return true
        }
        let indexedBytes = cached.parsedBytes ?? cached.size
        guard input.metadata.size > cached.size,
              indexedBytes > 0,
              let anchor = cached.codexTokenIndexAnchor,
              anchor.indexedBytes == indexedBytes
        else { return false }
        return Self.codexTokenIndexAnchorMatches(
            anchor,
            fileURL: input.fileURL,
            metadata: input.metadata)
    }

    private struct CodexOrdinaryForkBodyScanCandidate {
        let metadata: CodexSessionMetadata
        let sessionId: String
        let parentSessionId: String
        let cutoffTimestamp: String
        let metadataMatchesCurrentSource: Bool
    }

    private enum CodexForkBodyScanInspection {
        case decided(CodexForkBodyScanDecision)
        case ordinary(CodexOrdinaryForkBodyScanCandidate)
    }

    private enum CodexForkBodyScanAction {
        case decided(CodexForkBodyScanDecision)
        case retainCached
        case storeMarker(
            preparation: CodexBufferedForkDependencyPreparation,
            decision: CodexForkBodyScanDecision)
    }

    /// Ordinary fork bodies are useless until the exact inherited baseline is available. Keep the
    /// metadata inspection, ownership transaction, dependency lookup, and marker publication in
    /// separate stack frames: each operation has sizeable debug temporaries, while their effects
    /// must still occur in exactly that order.
    @inline(never)
    private static func prepareCodexForkBodyScan(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        preflightAfterCacheMiss: Bool = false) throws -> CodexForkBodyScanDecision
    {
        let inspection = try Self.inspectCodexForkBodyScan(
            input: input,
            context: context,
            preflightAfterCacheMiss: preflightAfterCacheMiss)
        guard case let .ordinary(candidate) = inspection else {
            guard case let .decided(decision) = inspection else { return .deferred }
            return decision
        }

        if candidate.metadataMatchesCurrentSource {
            guard Self.claimCodexForkSessionOwnership(
                input: input,
                sessionId: candidate.sessionId,
                forkedFromId: candidate.parentSessionId,
                context: context,
                cache: &cache,
                state: &state)
            else { return .deferred }
        }

        let action = try Self.planCodexOrdinaryForkBodyScan(
            input: input,
            candidate: candidate,
            context: context)
        switch action {
        case let .decided(decision):
            return decision
        case .retainCached:
            guard let cached = input.cached else { return .deferred }
            // Preserve the second ownership transaction formerly performed inside the retain
            // helper. Its rollback snapshot is intentionally taken after the first claim above.
            guard Self.claimCodexForkSessionOwnership(
                input: input,
                sessionId: cached.sessionId,
                forkedFromId: cached.forkedFromId,
                context: context,
                cache: &cache,
                state: &state)
            else {
                Self.rememberScannedCodexFile(
                    input: input,
                    session: CodexScannedSession(id: cached.sessionId, days: cached.days),
                    rows: [],
                    context: context,
                    state: &state)
                return .deferred
            }
            Self.retainCachedCodexFileDuringDeferralAfterOwnershipClaim(
                input: input,
                cached: cached,
                context: context,
                cache: &cache,
                state: &state)
            return .deferred
        case let .storeMarker(preparation, decision):
            // Marker publication used to claim recursively. Keep the same second transaction,
            // but let its frame unwind before constructing and publishing the marker.
            guard Self.claimCodexForkSessionOwnership(
                input: input,
                sessionId: candidate.metadata.sessionId,
                forkedFromId: candidate.metadata.forkedFromId,
                context: context,
                cache: &cache,
                state: &state)
            else { return .deferred }
            Self.storeDeferredCodexForkMarkerAfterOwnershipClaim(
                input: input,
                metadata: candidate.metadata,
                preparation: preparation,
                context: context,
                cache: &cache,
                state: &state)
            return decision
        }
    }

    /// Inspect only the bounded metadata prefix. This deliberately performs no ownership claim or
    /// cache/state marker mutation so its large parsing frame is gone before either operation.
    @inline(never)
    private static func inspectCodexForkBodyScan(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        preflightAfterCacheMiss: Bool) throws -> CodexForkBodyScanInspection
    {
        let cached = input.cached
        let cachedMarkerIsUnchanged = cached?.codexDeferredForkScan == true
            && cached?.codexScanFileId != nil
            && cached?.codexScanFileId == input.metadata.fileId
            && cached?.mtimeUnixMs == input.metadata.mtimeUnixMs
            && cached?.size == input.metadata.size
            && cached?.codexScanChangeUnixNs == input.metadata.changeUnixNs

        let forkMetadata: CodexSessionMetadata?
        let forkMetadataMatchesCurrentSource: Bool
        let cachedMarkerHasCompleteMetadata = cachedMarkerIsUnchanged
            && cached?.sessionId?.isEmpty == false
            && cached?.forkedFromId?.isEmpty == false
            && cached?.codexForkTimestamp?.isEmpty == false
        if cachedMarkerHasCompleteMetadata, let cached {
            forkMetadata = CodexSessionMetadata(
                sessionId: cached.sessionId,
                forkedFromId: cached.forkedFromId,
                forkTimestamp: cached.codexForkTimestamp,
                projectPath: cached.projectPath,
                isSubagentThread: false,
                subagentHistoryStartOrdinal: nil)
            forkMetadataMatchesCurrentSource = true
        } else if cached?.codexDeferredForkScan == true || preflightAfterCacheMiss {
            switch try Self.codexForkMetadataPreflight(input: input, context: context) {
            case let .scanned(metadata):
                forkMetadata = metadata
                forkMetadataMatchesCurrentSource = metadata != nil
            case .deferredByBudget:
                return .decided(.deferred)
            case .sourceMutated:
                return .decided(.deferred)
            }
        } else if let cached,
                  let metadata = Self.bufferedOrdinaryCodexForkMetadata(cached)
        {
            guard Self.cachedCodexForkMetadataStillMatchesSource(cached: cached, input: input)
            else { return .decided(.proceed) }
            forkMetadata = metadata
            forkMetadataMatchesCurrentSource = true
        } else {
            return .decided(.proceed)
        }

        guard Self.codexFileMetadataMatches(
            input.metadata,
            Self.codexFileMetadata(fileURL: input.fileURL))
        else {
            context.scanBudget?.recordSourceMutationDeferral()
            return .decided(.deferred)
        }

        if let sessionId = forkMetadata?.sessionId, !sessionId.isEmpty {
            // The bounded metadata read has already established this file's identity. Teach the
            // discovery index immediately so a missing-parent lookup does not reread the same
            // file head while the body parser is holding the refresh budget.
            context.resources.fileIndex.remember(fileURL: input.fileURL, sessionId: sessionId)
        }

        guard let forkMetadata,
              !forkMetadata.isSubagentThread,
              forkMetadata.subagentHistoryStartOrdinal == nil,
              let sessionId = forkMetadata.sessionId,
              !sessionId.isEmpty,
              let parentSessionId = forkMetadata.forkedFromId,
              !parentSessionId.isEmpty,
              let cutoffTimestamp = forkMetadata.forkTimestamp,
              !cutoffTimestamp.isEmpty
        else {
            return .decided(cached?.codexDeferredForkScan == true ? .restartFromByteZero : .proceed)
        }

        return .ordinary(CodexOrdinaryForkBodyScanCandidate(
            metadata: forkMetadata,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            cutoffTimestamp: cutoffTimestamp,
            metadataMatchesCurrentSource: forkMetadataMatchesCurrentSource))
    }

    /// Resolve the parent and choose the cache action without claiming ownership or publishing a
    /// marker. The small coordinator above performs those transactions after this frame unwinds.
    @inline(never)
    private static func planCodexOrdinaryForkBodyScan(
        input: CodexFileScanInput,
        candidate: CodexOrdinaryForkBodyScanCandidate,
        context: CodexFileScanContext) throws -> CodexForkBodyScanAction
    {
        let cached = input.cached
        let preparation = try Self.prepareCodexForkDependency(
            parentSessionId: candidate.parentSessionId,
            cutoffTimestamp: candidate.cutoffTimestamp,
            inheritedResolver: context.resources.inheritedResolver)
        guard Self.codexFileMetadataMatches(
            input.metadata,
            Self.codexFileMetadata(fileURL: input.fileURL))
        else {
            context.scanBudget?.recordSourceMutationDeferral()
            return .decided(.deferred)
        }
        let cachedPartialDependencyKey: String? = if let cached,
                                                     cached.codexScanComplete == false,
                                                     cached.codexDeferredForkScan != true,
                                                     (cached.parsedBytes ?? 0) > 0,
                                                     cached.codexForkAccountingState != nil,
                                                     !Self.cachedCodexRowsNeedIdentityRescan(cached),
                                                     cached.forkedFromId == candidate.parentSessionId,
                                                     cached.codexForkTimestamp == candidate.cutoffTimestamp,
                                                     cached.forkBaselineDependencyKey?.hasPrefix("file|") == true
        {
            cached.forkBaselineDependencyKey
        } else {
            nil
        }
        if preparation.isReady {
            // A bounded ordinary-fork body may already have parsed a validated prefix against
            // this exact completed parent. Preserve that cursor: replacing it with the transient
            // ready marker would reset `parsedBytes` to zero on every refresh, so a child larger
            // than one slice could never reach EOF. The append path below revalidates file ID,
            // prefix anchor, and JSONL resume offset before it reads the suffix.
            if let cachedDependencyKey = cachedPartialDependencyKey,
               let readyDependencyKey = preparation.stableDependencyKey,
               Self.codexResolvedForkDependencyKeysMatch(
                   cachedDependencyKey,
                   readyDependencyKey)
            {
                return .decided(.proceed)
            }
            // Preserve the zero-byte replay path for a validated legacy buffer. Every other
            // metadata-preflighted ordinary fork gets a transient marker: if the preflight used
            // the refresh's last bytes, the next refresh can skip that I/O and start at byte zero
            // instead of repeating the same metadata read forever.
            if cached?.codexDeferredForkScan != true,
               cached?.hasBufferedCodexForkRetryLines == true
            {
                return .decided(.proceed)
            }
            return .storeMarker(
                preparation: CodexBufferedForkDependencyPreparation(
                    cutoffTimestamp: preparation.cutoffTimestamp,
                    isReady: true,
                    stableDependencyKey: nil),
                decision: .restartFromByteZero)
        }

        // A transient lookup miss (for example a path alias that has not yet reconciled, an
        // incomplete parent, or a temporarily busy sidecar) is not evidence that the validated
        // parent generation changed. Keep the published child prefix until lookup either resolves
        // a concrete file key or proves a stable missing-parent generation; clearing it here would
        // turn every transient miss into a byte-zero restart and allow the cursor to regress.
        if preparation.stableDependencyKey == nil,
           cachedPartialDependencyKey != nil,
           cached != nil
        {
            return .retainCached
        }

        return .storeMarker(preparation: preparation, decision: .deferred)
    }

    private static func codexForkMetadataPreflight(
        input: CodexFileScanInput,
        context: CodexFileScanContext) throws -> CodexForkMetadataPreflightResult
    {
        let pendingBytes = min(
            max(0, input.metadata.size),
            Self.codexForkMetadataPreflightMaxBytes)
        let allowedBytes: Int64
        if let budget = context.scanBudget {
            let refreshRemaining = budget.maxBytesPerRefresh > 0
                ? max(0, budget.maxBytesPerRefresh - budget.bytesConsumed)
                : Int64.max
            if pendingBytes > 0, refreshRemaining <= pendingBytes {
                // Do not spend the refresh's entire remaining allowance rereading metadata and
                // leave no byte for the resumable body parser. Its bounded fallback preserves
                // progress; an ordinary fork will become a marker once session_meta is parsed.
                return .scanned(nil)
            }
            // A metadata probe often asks for the 256 KiB hard ceiling but finds session_meta in
            // the first line. Do not mark the refresh partial merely because the allowance is
            // smaller than that ceiling; record it only if the admitted prefix was insufficient.
            switch budget.admit(workBytes: pendingBytes, recordPartialWork: false) {
            case let .allow(allowance):
                allowedBytes = allowance
            case .deferBudget:
                return .deferredByBudget
            }
        } else {
            allowedBytes = pendingBytes
        }

        let result = try Self.scanCodexSessionMetadata(
            fileURL: input.fileURL,
            maxBytesToRead: allowedBytes,
            checkCancellation: context.checkCancellation)
        context.scanBudget?.complete(
            admittedWorkBytes: allowedBytes,
            actualWorkBytes: result.bytesRead)
        if result.metadata == nil, allowedBytes < pendingBytes {
            // The budget ended before the hard metadata window did. Do not treat an incomplete
            // prefix as proof that this is not an ordinary fork and start consuming its body.
            context.scanBudget?.recordPartialWork()
            return .deferredByBudget
        }
        guard Self.codexFileMetadataMatches(
            input.metadata,
            Self.codexFileMetadata(fileURL: input.fileURL))
        else {
            context.scanBudget?.recordSourceMutationDeferral()
            return .sourceMutated
        }
        return .scanned(result.metadata)
    }

    /// The caller has completed the ownership transaction and lets that frame unwind before
    /// entering this marker-construction frame.
    @inline(never)
    // swiftlint:disable:next function_parameter_count
    private static func storeDeferredCodexForkMarkerAfterOwnershipClaim(
        input: CodexFileScanInput,
        metadata: CodexSessionMetadata,
        preparation: CodexBufferedForkDependencyPreparation,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState)
    {
        if let previous = cache.files[input.metadata.path] {
            applyFileDays(cache: &cache, fileDays: previous.days, sign: -1)
        }

        let preflightSession = CostUsageCodexSessionMetadata(
            sessionId: metadata.sessionId,
            forkedFromId: metadata.forkedFromId,
            cwd: metadata.projectPath,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let canReuseCachedMetadata = input.cached?.codexScanFileId != nil
            && input.cached?.codexScanFileId == input.metadata.fileId
        let codexSession = if canReuseCachedMetadata, let cachedSession = input.cached?.codexSession {
            cachedSession.merging(preflightSession)
        } else {
            preflightSession
        }
        let canonicalProjectPath = context.resources.projectPathResolver
            .canonicalProjectPath(for: metadata.projectPath)
        let marker = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: [:],
            parsedBytes: 0,
            sessionId: metadata.sessionId,
            forkedFromId: metadata.forkedFromId,
            codexForkTimestamp: preparation.cutoffTimestamp,
            forkBaselineDependencyKey: preparation.stableDependencyKey,
            projectPath: metadata.projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexSession: codexSession.isEmpty ? nil : codexSession,
            codexScanFileId: input.metadata.fileId,
            codexScanChangeUnixNs: input.metadata.changeUnixNs,
            codexScanTargetSize: input.metadata.size,
            codexScanComplete: false,
            codexDeferredForkScan: true)
            .refreshingCodexWorkspaceUsageFingerprint()
        cache.files[input.metadata.path] = marker
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: metadata.sessionId, days: [:]),
            rows: [],
            context: context,
            state: &state)
    }

    private struct CodexFileBodyScanPlan {
        let input: CodexFileScanInput
        let pendingWorkBytes: Int64
        let allowedWorkBytes: Int64
    }

    /// Keep source inspection, fork ownership, and JSONL body work in sequential stack frames.
    /// Each phase carries substantial debug-only temporaries; nesting any pair can exhaust the
    /// smaller worker stacks used by Swift Testing even for a tiny bounded slice.
    private static func scanCodexFile(
        fileURL: URL,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws
    {
        guard let sourceInput = try prepareCodexFileBodyScan(
            fileURL: fileURL,
            context: context,
            cache: &cache,
            state: &state)
        else { return }
        guard let originalInput = try Self.prepareCodexDeferredReplayParent(
            input: sourceInput,
            context: context,
            cache: &cache,
            state: &state)
        else { return }

        let forkBodyDecision = try Self.prepareCodexForkBodyScan(
            input: originalInput,
            context: context,
            cache: &cache,
            state: &state)
        if case .deferred = forkBodyDecision {
            return
        }
        var input = CodexFileScanInput(
            fileURL: fileURL,
            metadata: originalInput.metadata,
            cached: forkBodyDecision == .restartFromByteZero ? nil : originalInput.cached)
        if try Self.keepCachedCodexFileIfFresh(
            input: input,
            context: context,
            cache: &cache,
            state: &state)
        {
            return
        }
        if forkBodyDecision == .proceed {
            let cacheMissDecision = try Self.prepareCodexForkBodyScan(
                input: originalInput,
                context: context,
                cache: &cache,
                state: &state,
                preflightAfterCacheMiss: true)
            if case .deferred = cacheMissDecision {
                return
            }
            if case .restartFromByteZero = cacheMissDecision {
                input = CodexFileScanInput(
                    fileURL: fileURL,
                    metadata: originalInput.metadata,
                    cached: nil)
            }
        }

        guard let plan = Self.prepareCodexFileBodyWork(input: input, context: context)
        else { return }

        if try Self.appendCodexFileIncrementIfPossible(
            input: plan.input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: plan.allowedWorkBytes)
        {
            context.scanBudget?.consumeFileBody(workBytes: plan.allowedWorkBytes)
            return
        }
        let fullRescanWorkBytes = max(0, plan.input.metadata.size)
        let fullRescanAllowedBytes: Int64
        if fullRescanWorkBytes == plan.pendingWorkBytes {
            fullRescanAllowedBytes = plan.allowedWorkBytes
        } else if let budget = context.scanBudget {
            budget.release(workBytes: plan.allowedWorkBytes)
            switch budget.admit(workBytes: fullRescanWorkBytes) {
            case let .allow(allowance):
                fullRescanAllowedBytes = allowance
            case .deferBudget:
                // No work was consumed by the rejected incremental path, so this is only
                // reachable when the refresh budget has no allowance for the full rescan.
                return
            }
        } else {
            fullRescanAllowedBytes = fullRescanWorkBytes
        }

        try Self.rescanCodexFile(
            input: plan.input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: fullRescanAllowedBytes)
        context.scanBudget?.consumeFileBody(workBytes: fullRescanAllowedBytes)
    }

    /// Validate and reconcile the source snapshot only. Replay-parent resolution and fork
    /// preflight deliberately happen in `scanCodexFile` after this large frame has returned.
    @inline(never)
    private static func prepareCodexFileBodyScan(
        fileURL: URL,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> CodexFileScanInput?
    {
        try context.checkCancellation?()
        let metadata = Self.codexFileMetadata(fileURL: fileURL)
        if let fileId = metadata.fileId, state.seenFileIds.contains(fileId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cache.files[metadata.path], cache: &cache)
            return nil
        }
        Self.reconcileCodexCachePathAliases(metadata: metadata, cache: &cache)

        var cached = cache.files[metadata.path]
        func deferredReplaySourceSnapshotMatches(_ usage: CostUsageFileUsage) -> Bool {
            usage.codexScanFileId != nil
                && usage.codexScanFileId == metadata.fileId
                && usage.size == metadata.size
                && usage.mtimeUnixMs == metadata.mtimeUnixMs
                && usage.codexScanChangeUnixNs != nil
                && usage.codexScanChangeUnixNs == metadata.changeUnixNs
                && usage.codexTokenIndexAnchor.map {
                    Self.codexTokenIndexAnchorMatches(
                        $0,
                        fileURL: fileURL,
                        metadata: metadata)
                } == true
        }
        if let replaying = cached,
           let replayState = replaying.codexDeferredReplayState,
           replayState.phase == .replaying,
           replayState.mode == .unresolvedFork,
           !deferredReplaySourceSnapshotMatches(replaying)
        {
            // An ordinary replay's cached parent/cutoff belongs to the indexed source snapshot.
            // Drop it before the parent gate so the normal cache-miss path preflights live
            // session_meta. This also removes any rows published by an interrupted replay.
            Self.dropCachedCodexFile(path: metadata.path, cached: replaying, cache: &cache)
            cached = nil
        }
        if var replaying = cached,
           var replayState = replaying.codexDeferredReplayState,
           replayState.phase == .replaying,
           replayState.mode != .unresolvedFork
        {
            if !deferredReplaySourceSnapshotMatches(replaying) {
                // Legacy classification is a property of the complete source snapshot. Growth,
                // truncation, atomic replacement, or an in-place rewrite can append/change
                // lineage after the old EOF; carrying the old mode into replay would be unsound.
                replayState = CostUsageCodexDeferredReplayState(
                    phase: .indexing,
                    mode: .legacySubagentClassification,
                    ownedSuffixStartOffset: nil,
                    rawTotalsBaseline: nil,
                    parentTotalsAtBoundary: nil,
                    legacySubagentShape: Self.initialLegacySubagentShapeState(
                        leafSessionId: nil),
                    replayStarted: false,
                    restartIndexingFromByteZero: true)
                replaying.codexDeferredReplayState = replayState
                replaying.forkedFromId = nil
                replaying.codexForkTimestamp = nil
                replaying.forkBaselineDependencyKey = nil
                if var session = replaying.codexSession {
                    session.forkedFromId = nil
                    replaying.codexSession = session
                }
                replaying.codexScanComplete = false
                cached = replaying
                cache.files[metadata.path] = replaying
            }
        }
        return CodexFileScanInput(fileURL: fileURL, metadata: metadata, cached: cached)
    }

    /// Resolve a replay's parent only after the source-snapshot frame has unwound. An unresolved
    /// parent still returns `nil` before fork preflight, body-budget admission, or JSONL parsing.
    @inline(never)
    private static func prepareCodexDeferredReplayParent(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> CodexFileScanInput?
    {
        guard var replaying = input.cached,
              var replayState = replaying.codexDeferredReplayState,
              replayState.phase == .replaying,
              replayState.mode == .unresolvedFork
              || replayState.mode == .inheritedSubagentFork
              || replayState.mode == .parentConfirmedSubagentCandidate
        else { return input }

        guard let parentSessionId = replaying.forkedFromId,
              !parentSessionId.isEmpty,
              let cutoffTimestamp = replaying.codexForkTimestamp,
              !cutoffTimestamp.isEmpty
        else {
            Self.rememberScannedCodexFile(
                input: CodexFileScanInput(
                    fileURL: input.fileURL,
                    metadata: input.metadata,
                    cached: replaying),
                session: CodexScannedSession(id: replaying.sessionId, days: replaying.days),
                rows: replaying.codexRows ?? [],
                context: context,
                state: &state)
            return nil
        }

        switch try context.resources.inheritedResolver.inheritedTotals(
            for: parentSessionId,
            atOrBefore: cutoffTimestamp)
        {
        case .unresolved:
            // Parent readiness is checked before admitting body bytes. An unchanged waiting
            // replay therefore performs zero JSONL work on every background refresh. Persist
            // a stable missing-generation key so it becomes quiescent; a transient lookup or
            // changed inventory clears that key and keeps the replay eligible for retry.
            replaying.forkBaselineDependencyKey = context.resources.inheritedResolver
                .dependencyKeyUsed(for: parentSessionId)
            cache.files[input.metadata.path] = replaying
            Self.rememberScannedCodexFile(
                input: CodexFileScanInput(
                    fileURL: input.fileURL,
                    metadata: input.metadata,
                    cached: replaying),
                session: CodexScannedSession(id: replaying.sessionId, days: replaying.days),
                rows: replaying.codexRows ?? [],
                context: context,
                state: &state)
            return nil
        case let .resolved(parentTotals):
            replaying.forkBaselineDependencyKey = context.resources.inheritedResolver
                .dependencyKeyUsed(for: parentSessionId)
            if replayState.mode == .parentConfirmedSubagentCandidate {
                replayState.mode = Self.codexTotalsEqual(
                    parentTotals,
                    replayState.parentTotalsAtBoundary)
                    ? .localSubagentSuffix
                    : .independentSubagent
            }
            replaying.codexDeferredReplayState = replayState
            cache.files[input.metadata.path] = replaying
            return CodexFileScanInput(
                fileURL: input.fileURL,
                metadata: input.metadata,
                cached: replaying)
        }
    }

    /// Admit only the body work after every cache/fork decision frame has unwound.
    @inline(never)
    private static func prepareCodexFileBodyWork(
        input: CodexFileScanInput,
        context: CodexFileScanContext) -> CodexFileBodyScanPlan?
    {
        let metadata = input.metadata
        let pendingWorkBytes = Self.pendingCodexScanWorkBytes(metadata: metadata, cached: input.cached)
        let allowedWorkBytes: Int64
        if let budget = context.scanBudget {
            switch budget.admit(workBytes: pendingWorkBytes) {
            case let .allow(allowance):
                allowedWorkBytes = allowance
            case .deferBudget:
                Self.log.debug(
                    "Deferring Codex session cost scan until a later refresh",
                    metadata: [
                        "path": metadata.path,
                        "pendingBytes": "\(pendingWorkBytes)",
                        "consumed": "\(budget.bytesConsumed)",
                        "limit": "\(budget.maxBytesPerRefresh)",
                    ])
                // Preserve stale cache so later refreshes can resume catch-up.
                return nil
            }
        } else {
            allowedWorkBytes = pendingWorkBytes
        }

        return CodexFileBodyScanPlan(
            input: input,
            pendingWorkBytes: pendingWorkBytes,
            allowedWorkBytes: allowedWorkBytes)
    }

    static func pendingCodexScanWorkBytes(metadata: CodexFileMetadata, cached: CostUsageFileUsage?) -> Int64 {
        // Called only after keepCachedCodexFileIfFresh failed. Forced rescans, priority invalidation,
        // and other paths that reread JSONL must still charge the file; the sole zero-work exception
        // is a validated same-size buffered replay.
        guard let cached else { return max(0, metadata.size) }
        if cached.codexDeferredReplayState?.restartIndexingFromByteZero == true {
            return max(0, metadata.size)
        }
        if let replay = cached.codexDeferredReplayState, replay.phase == .replaying {
            if cached.hasSettledDeferredCodexReplay { return 0 }
            if replay.replayStarted == true {
                return max(0, metadata.size - (cached.parsedBytes ?? 0))
            }
            return max(0, metadata.size)
        }
        if Self.isValidatedSameSizeBufferedCodexForkRetry(metadata: metadata, cached: cached) {
            return 0
        }
        if Self.isAppendSafeBufferedCodexForkResume(metadata: metadata, cached: cached) {
            let startOffset = cached.parsedBytes ?? cached.size
            return max(0, metadata.size - startOffset)
        }
        if cached.codexScanComplete == false {
            if cached.codexScanFileId != nil,
               cached.codexScanFileId == metadata.fileId,
               let parsedBytes = cached.parsedBytes,
               parsedBytes > 0,
               parsedBytes <= metadata.size,
               cached.codexTokenIndexAnchor?.indexedBytes == parsedBytes,
               cached.codexTokenIndexAnchor.map({
                   Self.codexTokenIndexAnchorMatches(
                       $0,
                       fileURL: URL(fileURLWithPath: metadata.path),
                       metadata: metadata)
               }) == true
            {
                return max(0, metadata.size - parsedBytes)
            }
            return max(0, metadata.size)
        }
        let startOffset = cached.parsedBytes ?? cached.size
        if Self.isAppendSafeCodexNonForkResume(metadata: metadata, cached: cached) {
            return max(0, metadata.size - startOffset)
        }
        if Self.isAppendSafeCodexOrdinalSubagentResume(metadata: metadata, cached: cached) {
            return max(0, metadata.size - startOffset)
        }
        return max(0, metadata.size)
    }

    private static func makeCodexRefreshPlan(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date,
        nowMs: Int64,
        options: Options) -> CodexRefreshPlan
    {
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let roots = self.codexSessionsRoots(options: options)
        let rootsFingerprint = Self.codexRootsFingerprint(roots)
        let rootsChanged = cache.roots != rootsFingerprint
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let needsCostCacheMigration = cache.files.values.contains { Self.needsCodexCostCache($0, range: range) }
        let needsProjectMetadataMigration = cache.codexProjectMetadataVersion != Self.codexProjectMetadataVersion
        let modelsDevLoad = ModelsDevCache.load(now: now, cacheRoot: options.cacheRoot)
        let modelsDevCatalog = modelsDevLoad.artifact?.catalog
        let codexPricingKey = Self.codexPricingKey(modelsDevArtifact: modelsDevLoad.artifact)
        let codexPriorityMetadataKey = Self.codexPriorityMetadataKey(databaseURL: options.codexTraceDatabaseURL)
        let hasPriorityMetadata = codexPriorityMetadataKey.hasPrefix("sqlite:")
        let pricingChanged = cache.codexPricingKey != nil && cache.codexPricingKey != codexPricingKey
        let priorityMetadataChanged = Self.codexPriorityMetadataChanged(
            old: cache.codexPriorityMetadataKey,
            new: codexPriorityMetadataKey)
        let needsTurnIDCacheMigration = hasPriorityMetadata && cache.files.values.contains {
            $0.codexTurnIDs == nil
                && $0.codexUsageRowSidecarState == nil
                && $0.touchesCodexScanWindow(
                    sinceKey: range.scanSinceKey,
                    untilKey: range.scanUntilKey)
        }
        let shouldInspectPriorityTurns = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsProjectMetadataMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let priorityTurns = shouldInspectPriorityTurns ? Self.codexPriorityTurns(
            databaseURL: options.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey) : [:]
        let priorityTurnKeys = Self.codexPriorityTurnKeys(priorityTurns, calendar: range.calendar)
        let priorityTurnIDsByDay = Self.codexPriorityTurnIDsByDay(priorityTurns, calendar: range.calendar)
        let priorityTurnsChanged = shouldInspectPriorityTurns
            && hasPriorityMetadata
            && Self.codexPriorityTurnKeysChanged(
                old: cache.codexPriorityTurnKeys,
                new: priorityTurnKeys,
                range: range)
        let changedPriorityTurnIDs = shouldInspectPriorityTurns && hasPriorityMetadata
            ? Self.changedPriorityTurnIDs(
                old: cache.codexPriorityTurnIDsByDay,
                new: priorityTurnIDsByDay,
                oldKeys: cache.codexPriorityTurnKeys,
                newKeys: priorityTurnKeys,
                range: range)
            : []
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsProjectMetadataMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || priorityTurnsChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        return CodexRefreshPlan(
            refreshMs: refreshMs,
            roots: roots,
            rootsFingerprint: rootsFingerprint,
            rootsChanged: rootsChanged,
            windowExpanded: windowExpanded,
            needsCostCacheMigration: needsCostCacheMigration,
            needsProjectMetadataMigration: needsProjectMetadataMigration,
            modelsDevCatalog: modelsDevCatalog,
            codexPricingKey: codexPricingKey,
            codexPriorityMetadataKey: codexPriorityMetadataKey,
            hasPriorityMetadata: hasPriorityMetadata,
            priorityTurns: priorityTurns,
            priorityTurnKeys: priorityTurnKeys,
            priorityTurnIDsByDay: priorityTurnIDsByDay,
            pricingChanged: pricingChanged,
            priorityMetadataChanged: priorityMetadataChanged,
            priorityTurnsChanged: priorityTurnsChanged,
            needsTurnIDCacheMigration: needsTurnIDCacheMigration,
            changedPriorityTurnIDs: changedPriorityTurnIDs,
            shouldRefresh: shouldRefresh)
    }

    private static func loadCodexCache(
        options: Options,
        range: CostUsageDayRange) -> CostUsageCodexCacheLoadResult
    {
        CostUsageCacheIO.loadCodexForMigration(
            cacheRoot: options.cacheRoot,
            calendar: range.calendar)
    }

    private static func codexPreviousReportCandidate(
        cache: CostUsageCache,
        incompatibleCache: CostUsageCache?,
        range: CostUsageDayRange,
        plan: CodexRefreshPlan,
        options: Options) -> CostUsageCodexPreviousReport?
    {
        let currentScanIsPending = cache.codexScanCatchUpPending == true
            || cache.files.values.contains { $0.hasRetryableBufferedCodexFork }
        if currentScanIsPending,
           let previous = self.codexPreviousReport(
               cache: cache,
               range: range,
               rootsFingerprint: plan.rootsFingerprint)
        {
            return previous
        }

        let sourceCache: CostUsageCache? = if let incompatibleCache {
            incompatibleCache
        } else if !currentScanIsPending,
                  options.forceRescan,
                  !cache.days.isEmpty
        {
            cache
        } else {
            nil
        }
        guard let sourceCache,
              sourceCache.timeZoneIdentifier == range.calendar.timeZone.identifier,
              sourceCache.roots == plan.rootsFingerprint,
              !self.requestedWindowExpandsCache(range: range, cache: sourceCache),
              !sourceCache.days.isEmpty
        else { return nil }

        let report = self.buildCodexReportFromCache(
            cache: sourceCache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
        return CostUsageCodexPreviousReport(report: report, cache: sourceCache)
    }

    static func codexPreviousReport(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> CostUsageCodexPreviousReport?
    {
        guard cache.codexScanCatchUpPending == true,
              let previous = cache.codexPreviousReport,
              previous.matches(
                  scanSinceKey: range.sinceKey,
                  scanUntilKey: range.untilKey,
                  timeZoneIdentifier: range.calendar.timeZone.identifier,
                  roots: rootsFingerprint)
        else { return nil }
        return previous
    }

    private static func saveCodexCache(_ cache: CostUsageCache, options: Options, range: CostUsageDayRange) {
        // Provider-specific by design: Codex scans persist resume and report-window metadata.
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: options.cacheRoot,
            calendar: range.calendar,
            requestedScanWindow: (sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey),
            reportWindow: (sinceKey: range.sinceKey, untilKey: range.untilKey))
    }

    private static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        try self.loadCodexDailyOutcome(
            range: range,
            now: now,
            options: options,
            checkCancellation: checkCancellation).report
    }

    private static func loadCodexDailyOutcome(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CodexDailyLoadOutcome
    {
        let acquisition: CostUsageCodexRefreshLock.Acquisition
        do {
            acquisition = try CostUsageCodexRefreshLock.tryAcquire(
                cacheRoot: options.cacheRoot,
                lockDomainRoot: options.codexRefreshLockRoot)
        } catch {
            Self.log.warning(
                "Codex cost refresh lock unavailable; returning the published cache read-only",
                metadata: ["error": error.localizedDescription])
            return CodexDailyLoadOutcome(
                report: Self.loadCodexDailyReadOnly(range: range, now: now, options: options),
                disposition: .refreshLockUnavailable)
        }

        switch acquisition {
        case let .acquired(lease):
            defer { lease.release() }
            return try CodexDailyLoadOutcome(
                report: Self.loadCodexDailyOwned(
                    range: range,
                    now: now,
                    options: options,
                    checkCancellation: checkCancellation),
                disposition: .ownedRefresh)
        case .contended:
            return CodexDailyLoadOutcome(
                report: Self.loadCodexDailyReadOnly(range: range, now: now, options: options),
                disposition: .deferredByConcurrentWriter)
        }
    }

    private static func loadCodexDailyReadOnly(
        range: CostUsageDayRange,
        now: Date,
        options: Options) -> CostUsageDailyReport
    {
        let loadedCache = Self.loadCodexCache(options: options, range: range)
        let cache = loadedCache.cache
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = Self.makeCodexRefreshPlan(
            cache: cache,
            range: range,
            now: now,
            nowMs: nowMs,
            options: options)
        if let previous = Self.codexPreviousReportCandidate(
            cache: cache,
            incompatibleCache: loadedCache.incompatibleCache,
            range: range,
            plan: plan,
            options: options)
        {
            return previous.report
        }
        return Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func loadCodexDailyOwned(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let loadedCache = Self.loadCodexCache(options: options, range: range)
        var cache = loadedCache.cache
        Self.captureCodexUsageRowProducerKeys(cache: &cache)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = Self.makeCodexRefreshPlan(cache: cache, range: range, now: now, nowMs: nowMs, options: options)
        let previousReport = Self.codexPreviousReportCandidate(
            cache: cache,
            incompatibleCache: loadedCache.incompatibleCache,
            range: range,
            plan: plan,
            options: options)
        let requiresEOFForkRevalidation = Self.revalidatePreEOFCodexForkBaselines(cache: &cache)

        if plan.shouldRefresh || requiresEOFForkRevalidation {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
            let coldCacheLookbackStart = Self.localStartOfDay(range.scanSinceKey, calendar: options.calendar)
            let scanBudget = CodexScanBudget(
                maxFileBytes: options.maxCodexSessionFileBytes,
                maxBytesPerRefresh: options.maxCodexScanBytesPerRefresh,
                maxDuration: options.maxCodexScanDurationPerRefresh)
            defer {
                options.codexScanWorkRecorderForTesting?.record(
                    budgetBytesConsumed: scanBudget.bytesConsumed,
                    fileBodyBudgetBytesConsumed: scanBudget.fileBodyBudgetBytesConsumed,
                    fileParseInvocations: scanBudget.fileParseInvocationCount,
                    usageRowsRead: scanBudget.usageRowsRead,
                    usageRowDeltaProcessed: scanBudget.usageRowDeltaProcessed,
                    usageRowsWritten: scanBudget.usageRowsWritten,
                    usageRowsRepriced: scanBudget.usageRowsRepriced,
                    usageRowsFingerprintHashed: scanBudget.usageRowsFingerprintHashed)
            }
            var activeLookbackState = Self.codexActiveLookbackState(
                cache: cache,
                roots: plan.roots,
                scanSinceKey: range.scanSinceKey,
                includeLegacyRecursiveScan: shouldRunColdCacheLookback)
            var seenPaths: Set<String> = []
            var files: [URL] = []
            for root in plan.roots {
                let rootFiles = Self.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: range.scanSinceKey,
                    scanUntilKey: range.scanUntilKey,
                    includeRecursive: options.forceRescan,
                    calendar: options.calendar)
                for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                    seenPaths.insert(fileURL.path)
                    files.append(fileURL)
                }

                // The lookback runs on every refresh, not just cold ones: a session
                // resumed in an older date partition is appended to in place, so the
                // in-window partition listing never sees it and `cachedCodexSessionFiles`
                // cannot either until it has been scanned once. Without this, such a
                // session's usage stays invisible until a forced rescan.
                //
                // Partition discovery and any discovered candidates persist across bounded
                // passes. That prevents a small budget from restarting at the oldest day or
                // rediscovering a file without ever leaving enough budget to parse it.
                if let coldCacheLookbackStart {
                    Self.advanceCodexActiveLookback(
                        root: root,
                        range: range,
                        modifiedSince: coldCacheLookbackStart,
                        scanBudget: scanBudget,
                        state: &activeLookbackState)
                }
            }

            Self.appendPendingCodexActiveLookbackFiles(
                state: &activeLookbackState,
                roots: plan.roots,
                seenPaths: &seenPaths,
                files: &files)

            for fileURL in Self.cachedCodexSessionFiles(
                cache: cache,
                range: range,
                roots: plan.roots,
                excludingPaths: seenPaths)
                .sorted(by: { $0.path < $1.path })
            {
                seenPaths.insert(fileURL.path)
                files.append(fileURL)
            }

            if options.preferNewestCodexSessionsFirst {
                files = Self.sortedCodexSessionFilesNewestFirst(files)
            }
            files = Self.schedulingCodexForegroundBeforeDependencies(files, cache: &cache)

            var filePathsInScan = Set(files.map(\.path))
            let fileIndex = CodexSessionFileIndex(
                files: files,
                roots: plan.roots,
                cachedSessionFiles: Self.cachedCodexSessionIndex(
                    cache: cache,
                    roots: plan.roots,
                    knownExistingPaths: filePathsInScan),
                cachedDiscovery: plan.rootsChanged ? nil : cache.codexSessionDiscovery,
                scanBudget: scanBudget,
                headParseObserver: self.codexSessionHeadParseObserverStore?.observer,
                checkCancellation: checkCancellation)
            let tokenIndexStore = CostUsageCodexTokenIndexStore(cacheRoot: options.cacheRoot)
            let usageRowStore = CostUsageCodexUsageRowStore(cacheRoot: options.cacheRoot)
            Self.prepareCodexUsageRowStoreForOwnedRefresh(
                cache: &cache,
                store: usageRowStore)
            let inheritedResolver = CodexInheritedTotalsResolver(
                fileIndex: fileIndex,
                checkCancellation: checkCancellation,
                scanBudget: scanBudget,
                tokenIndexStore: tokenIndexStore,
                cachedFiles: cache.files)
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver,
                tokenIndexStore: tokenIndexStore,
                usageRowStore: usageRowStore,
                projectPathResolver: CodexCanonicalProjectPathResolver(),
                modelsDevCatalog: plan.modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                priorityTurns: plan.priorityTurns,
                publishedProducerKey: CostUsageCacheIO.currentProducerKey(provider: .codex)
                    ?? "codex:unknown",
                currentProducerKey: CostUsageCacheIO.currentProducerKey(provider: .codex)
                    ?? "codex:unknown",
                pricingKey: plan.codexPricingKey,
                priorityMetadataKey: plan.codexPriorityMetadataKey,
                timeZoneIdentifier: range.calendar.timeZone.identifier)
            let scanContext = Self.codexFileScanContext(
                range: range,
                options: options,
                plan: plan,
                resources: resources,
                checkCancellation: checkCancellation,
                scanBudget: scanBudget)
            try filePathsInScan.formUnion(Self.scanCodexFiles(
                files,
                context: scanContext,
                cache: &cache,
                inheritedResolver: inheritedResolver))
            let scanWorkWasDeferred = scanBudget.resumedPartialFileCount > 0
                || scanBudget.deferredByBudgetFileCount > 0
                || scanBudget.deferredByTimeBudgetFileCount > 0
                || scanBudget.deferredBySourceMutationFileCount > 0
                || scanBudget.deferredByPersistenceFileCount > 0
            let hasScheduledUnfinishedWork = filePathsInScan.contains { path in
                let usage = Self.cachedCodexUsage(
                    fileURL: URL(fileURLWithPath: path),
                    cache: cache)
                return usage?.hasRetryableBufferedCodexFork == true
                    || (usage?.codexScanComplete == false
                        && usage?.hasSettledDeferredCodexFork != true
                        && usage?.hasSettledDeferredCodexReplay != true)
            }
            cache.codexActiveLookbackState = Self.finalizedCodexActiveLookbackState(
                activeLookbackState,
                cache: cache,
                retainCompletedState: scanWorkWasDeferred || hasScheduledUnfinishedWork)
            if scanBudget.resumedPartialFileCount > 0
                || scanBudget.deferredByBudgetFileCount > 0
                || scanBudget.deferredByTimeBudgetFileCount > 0
                || scanBudget.deferredBySourceMutationFileCount > 0
                || scanBudget.deferredByPersistenceFileCount > 0
            {
                Self.log.info(
                    "Codex cost scan applied work limits",
                    metadata: [
                        "partialFiles": "\(scanBudget.resumedPartialFileCount)",
                        "deferredByBudget": "\(scanBudget.deferredByBudgetFileCount)",
                        "deferredByTime": "\(scanBudget.deferredByTimeBudgetFileCount)",
                        "deferredByMutation": "\(scanBudget.deferredBySourceMutationFileCount)",
                        "deferredByPersistence": "\(scanBudget.deferredByPersistenceFileCount)",
                        "bytesConsumed": "\(scanBudget.bytesConsumed)",
                        "maxFileBytes": "\(scanBudget.maxFileBytes)",
                        "maxBytesPerRefresh": "\(scanBudget.maxBytesPerRefresh)",
                    ])
            }
            try checkCancellation?()

            Self.pruneForceRescanFilesOutsideWindow(
                cache: &cache,
                range: range,
                isForceRescan: options.forceRescan)

            let shouldDropAllUnscannedFiles = options.forceRescan || plan.rootsChanged || cache.files.isEmpty
                || plan.needsProjectMetadataMigration
            for key in cache.files.keys where !filePathsInScan.contains(key) {
                guard let old = cache.files[key] else { continue }
                let shouldDrop = shouldDropAllUnscannedFiles ||
                    old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                guard shouldDrop else { continue }
                Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                cache.files.removeValue(forKey: key)
            }

            if !shouldDropAllUnscannedFiles {
                for key in cache.files.keys {
                    guard let old = cache.files[key] else { continue }
                    guard old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                    else { continue }
                    guard FileManager.default.fileExists(atPath: key) else {
                        Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                        cache.files.removeValue(forKey: key)
                        continue
                    }
                }
            }

            let shouldRetainWiderWindow = !options.forceRescan && !plan.pricingChanged && !plan
                .priorityMetadataChanged && !plan.needsTurnIDCacheMigration && !plan.needsProjectMetadataMigration
            let retainedSinceKey = shouldRetainWiderWindow
                ? [cache.scanSinceKey, range.scanSinceKey].compactMap(\.self).min() ?? range.scanSinceKey
                : range.scanSinceKey
            let retainedUntilKey = shouldRetainWiderWindow
                ? [cache.scanUntilKey, range.scanUntilKey].compactMap(\.self).max() ?? range.scanUntilKey
                : range.scanUntilKey
            Self.pruneDays(cache: &cache, sinceKey: retainedSinceKey, untilKey: retainedUntilKey)
            cache.roots = plan.rootsFingerprint
            cache.scanSinceKey = retainedSinceKey
            cache.scanUntilKey = retainedUntilKey
            cache.codexPricingKey = plan.codexPricingKey
            cache.codexPriorityMetadataKey = plan.codexPriorityMetadataKey
            cache.codexProjectMetadataVersion = Self.codexProjectMetadataVersion
            let scanProgress = Self.codexScanProgress(paths: filePathsInScan, cache: cache)
            cache.codexScanProcessedBytes = scanProgress.processedBytes
            cache.codexScanTotalBytes = scanProgress.totalBytes
            cache.codexScanCompletedFiles = scanProgress.completedFiles
            cache.codexScanTotalFiles = scanProgress.totalFiles
            cache.codexSessionDiscovery = fileIndex.persistedState
            let catchUpPending = scanBudget.resumedPartialFileCount > 0
                || scanBudget.deferredByBudgetFileCount > 0
                || scanBudget.deferredByTimeBudgetFileCount > 0
                || scanBudget.deferredBySourceMutationFileCount > 0
                || scanBudget.deferredByPersistenceFileCount > 0
                || scanProgress.completedFiles < scanProgress.totalFiles
                || cache.files.values.contains { $0.hasRetryableBufferedCodexFork }
                || fileIndex.hasPendingDiscovery
                || cache.codexActiveLookbackState != nil
            cache.codexScanCatchUpPending = catchUpPending
            cache.codexPreviousReport = catchUpPending ? previousReport : nil
            if plan.hasPriorityMetadata {
                cache.codexPriorityTurnKeys = Self.mergePriorityTurnKeys(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnKeys : nil,
                    new: plan.priorityTurnKeys,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
                cache.codexPriorityTurnIDsByDay = Self.mergePriorityTurnIDsByDay(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnIDsByDay : nil,
                    new: plan.priorityTurnIDsByDay,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
            }
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            Self.saveCodexCache(cache, options: options, range: range)
            // Maintenance uses wall-clock time rather than the report's injected `now`; a caller
            // requesting historical/future data must not age generations into deletion. Gate the
            // raw JSON reload first so Finish Now does not decode a large artifact every pass.
            let maintenanceNow = Date()
            if usageRowStore.shouldRunGarbageCollection(now: maintenanceNow) {
                // Reload the atomically published artifact before GC: save-time budget pruning may
                // remove entries from its private copy, and a failed save leaves the previous JSON
                // in place. Protecting exactly what readers can observe makes cleanup crash-safe.
                if let publishedGenerationIDs = CostUsageCacheIO
                    .loadPublishedCodexUsageRowGenerationIDs(cacheRoot: options.cacheRoot)
                {
                    do {
                        _ = try usageRowStore.garbageCollect(
                            publishedGenerationIDs: publishedGenerationIDs,
                            gracePeriod: 24 * 60 * 60,
                            now: maintenanceNow)
                    } catch {
                        usageRowStore.recordSkippedGarbageCollectionAttempt(
                            now: maintenanceNow,
                            failure: error)
                        Self.log.debug(
                            "Codex usage-row sidecar garbage collection deferred",
                            metadata: ["error": "\(error)"])
                    }
                } else {
                    // A malformed, oversized, or transiently unreadable publication must fail
                    // closed. Record the attempt so it is not reread on every bounded pass.
                    usageRowStore.recordSkippedGarbageCollectionAttempt(now: maintenanceNow)
                    Self.log.debug(
                        "Codex usage-row sidecar garbage collection skipped; published cache unavailable")
                }
            }
        }

        if let previous = Self.codexPreviousReport(
            cache: cache,
            range: range,
            rootsFingerprint: plan.rootsFingerprint)
        {
            return previous.report
        }
        return Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }

    private struct CodexScanProgressSummary {
        let processedBytes: Int64
        let totalBytes: Int64
        let completedFiles: Int
        let totalFiles: Int
    }

    private static func codexScanProgress(
        paths: Set<String>,
        cache: CostUsageCache) -> CodexScanProgressSummary
    {
        var processedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var completedFiles = 0
        var totalFiles = 0
        var seenIdentities: Set<String> = []

        for path in paths.sorted() {
            let fileURL = URL(fileURLWithPath: path)
            let metadata = Self.codexFileMetadata(fileURL: fileURL)
            let identity = metadata.fileId ?? fileURL.standardizedFileURL.path
            guard seenIdentities.insert(identity).inserted else { continue }
            totalFiles += 1
            totalBytes += max(0, metadata.size)

            let usage = cache.files[path] ?? cache.files[fileURL.standardizedFileURL.path]
            guard let usage else { continue }
            let identityMatches = usage.codexScanFileId == nil || usage.codexScanFileId == metadata.fileId
            guard identityMatches else { continue }
            if usage.hasSettledDeferredCodexFork || usage.hasSettledDeferredCodexReplay {
                // The body is intentionally unread, so do not inflate processed bytes. A stable
                // missing-parent dependency is nevertheless quiescent work and must not leave the
                // catch-up worker or UI permanently active.
                if usage.hasSettledDeferredCodexReplay {
                    // Raw indexing already reached EOF before this classified replay began.
                    processedBytes += max(0, metadata.size)
                }
                completedFiles += 1
                continue
            }
            if usage.codexDeferredReplayState?.phase == .replaying {
                // The UI reports raw-index progress, not the internal classified replay cursor.
                // Keeping the source size here makes progress monotonic while catch-up remains
                // pending until the replay plan retires.
                processedBytes += max(0, metadata.size)
                continue
            }
            let parsedBytes = min(
                max(0, metadata.size),
                max(0, usage.parsedBytes ?? (usage.codexScanComplete == false ? 0 : usage.size)))
            processedBytes += parsedBytes
            if usage.codexScanComplete != false,
               parsedBytes >= metadata.size,
               !usage.hasRetryableBufferedCodexFork
            {
                completedFiles += 1
            }
        }

        return CodexScanProgressSummary(
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: totalFiles)
    }

    private static func scanCodexFiles(
        _ files: [URL],
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        inheritedResolver: CodexInheritedTotalsResolver) throws -> Set<String>
    {
        var scanState = CodexScanState()
        var bufferedForkRetries: [URL] = []
        var visitedPaths: Set<String> = []
        var scannedPaths = Set(files.map(\.path))
        for fileURL in files {
            guard visitedPaths.insert(fileURL.standardizedFileURL.path).inserted else { continue }
            try Self.scanCodexFile(
                fileURL: fileURL,
                context: context,
                cache: &cache,
                state: &scanState)
            let usage = Self.cachedCodexUsage(fileURL: fileURL, cache: cache)
            inheritedResolver.updateCachedUsage(fileURL: fileURL, usage: usage)
            if Self.shouldRetryBufferedCodexFork(usage) {
                bufferedForkRetries.append(fileURL)
            }

            // The schedule admits one foreground slice before dependency work. Drain here so an
            // out-of-window parent occupies the dependency lane instead of falling behind the
            // remaining foreground backlog.
            try Self.scanPendingCodexParentFiles(
                context: context,
                cache: &cache,
                inheritedResolver: inheritedResolver,
                state: &scanState,
                visitedPaths: &visitedPaths,
                scannedPaths: &scannedPaths,
                bufferedForkRetries: &bufferedForkRetries)
        }

        // A final drain covers parents queued by the last file without making scheduling depend on
        // whether that file was already known in the main list.
        try Self.scanPendingCodexParentFiles(
            context: context,
            cache: &cache,
            inheritedResolver: inheritedResolver,
            state: &scanState,
            visitedPaths: &visitedPaths,
            scannedPaths: &scannedPaths,
            bufferedForkRetries: &bufferedForkRetries)

        // Newest-first ordering commonly encounters a child before its parent. Once this
        // refresh has indexed the parent, replay the child's compact parsed events in memory;
        // do not reread the JSONL or wait for another refresh.
        var retryState = scanState
        // Retain cross-file/session ownership and row identity from the primary pass, but allow
        // each buffered source to be revisited once now that its parent is available.
        retryState.seenFileIds.removeAll(keepingCapacity: true)
        var retriedPaths: Set<String> = []
        for fileURL in bufferedForkRetries where retriedPaths.insert(fileURL.path).inserted {
            guard Self.shouldRetryBufferedCodexFork(
                Self.cachedCodexUsage(fileURL: fileURL, cache: cache))
            else { continue }
            try Self.scanCodexFile(
                fileURL: fileURL,
                context: context,
                cache: &cache,
                state: &retryState)
            inheritedResolver.updateCachedUsage(
                fileURL: fileURL,
                usage: Self.cachedCodexUsage(fileURL: fileURL, cache: cache))
        }
        return scannedPaths
    }

    // The shared inout collections are the scheduler state drained by this helper.
    // swiftlint:disable:next function_parameter_count
    private static func scanPendingCodexParentFiles(
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        inheritedResolver: CodexInheritedTotalsResolver,
        state: inout CodexScanState,
        visitedPaths: inout Set<String>,
        scannedPaths: inout Set<String>,
        bufferedForkRetries: inout [URL]) throws
    {
        while true {
            let pendingParents = inheritedResolver.takePendingParentFiles().filter {
                visitedPaths.insert($0.standardizedFileURL.path).inserted
            }
            guard !pendingParents.isEmpty else { return }
            for fileURL in pendingParents {
                scannedPaths.insert(fileURL.path)
                try Self.scanCodexFile(
                    fileURL: fileURL,
                    context: context,
                    cache: &cache,
                    state: &state)
                let usage = Self.cachedCodexUsage(fileURL: fileURL, cache: cache)
                inheritedResolver.updateCachedUsage(fileURL: fileURL, usage: usage)
                if Self.shouldRetryBufferedCodexFork(usage) {
                    bufferedForkRetries.append(fileURL)
                }
            }
        }
    }

    private static func shouldRetryBufferedCodexFork(_ usage: CostUsageFileUsage?) -> Bool {
        usage?.hasRetryableBufferedCodexFork == true
            || (usage?.deferredCodexReplayRequiresParent == true
                && usage?.hasSettledDeferredCodexReplay != true)
    }

    private static func cachedCodexUsage(
        fileURL: URL,
        cache: CostUsageCache) -> CostUsageFileUsage?
    {
        let metadataPath = Self.codexFileMetadata(fileURL: fileURL).path
        return cache.files[metadataPath]
            ?? cache.files[fileURL.path]
            ?? cache.files[fileURL.standardizedFileURL.path]
    }

    private static func codexFileScanContext(
        range: CostUsageDayRange,
        options: Options,
        plan: CodexRefreshPlan,
        resources: CodexScanResources,
        checkCancellation: CancellationCheck?,
        scanBudget: CodexScanBudget? = nil) -> CodexFileScanContext
    {
        CodexFileScanContext(
            range: range,
            forceFullScan: options.forceRescan || plan.windowExpanded || plan.pricingChanged
                || plan.needsProjectMetadataMigration,
            dropDeferredCodexRows: options.forceRescan || plan.pricingChanged || plan.priorityMetadataChanged
                || plan.needsTurnIDCacheMigration,
            requiresTurnIDCache: plan.needsTurnIDCacheMigration,
            changedPriorityTurnIDs: plan.changedPriorityTurnIDs,
            resources: resources,
            checkCancellation: checkCancellation,
            scanBudget: scanBudget)
    }

    static func sortedCodexSessionFilesNewestFirst(_ files: [URL]) -> [URL] {
        let metadata = files.reduce(into: [String: CodexFileMetadata]()) { result, fileURL in
            result[fileURL.path] = Self.codexFileMetadata(fileURL: fileURL)
        }
        return files.sorted { lhs, rhs in
            let left = metadata[lhs.path] ?? Self.codexFileMetadata(fileURL: lhs)
            let right = metadata[rhs.path] ?? Self.codexFileMetadata(fileURL: rhs)
            if left.mtimeUnixMs != right.mtimeUnixMs {
                return left.mtimeUnixMs > right.mtimeUnixMs
            }
            if left.size != right.size {
                return left.size < right.size
            }
            return lhs.path < rhs.path
        }
    }

    static func schedulingCodexForegroundBeforeDependencies(
        _ files: [URL],
        cache: inout CostUsageCache) -> [URL]
    {
        let usageBySessionId = cache.files.values.reduce(into: [String: CostUsageFileUsage]()) { out, usage in
            guard let sessionId = usage.sessionId else { return }
            out[sessionId] = usage
        }
        let dependencyParentIds = Set(cache.files.values.compactMap { usage -> String? in
            usage.hasRetryableBufferedCodexFork || usage.deferredCodexReplayRequiresParent
                ? usage.forkedFromId
                : nil
        })

        struct ScheduledFile {
            let fileURL: URL
            let originalIndex: Int
            let isBackground: Bool
            let progress: Int64
            let childBeforeParent: Bool
        }

        let scheduled = files.enumerated().map { index, fileURL in
            let usage = cache.files[fileURL.path] ?? cache.files[fileURL.standardizedFileURL.path]
            let isChild = usage?.hasRetryableBufferedCodexFork == true
                || usage?.deferredCodexReplayRequiresParent == true
            let isParent = usage?.sessionId.map(dependencyParentIds.contains) == true
            let parentUsage = isChild
                ? usage?.forkedFromId.flatMap { usageBySessionId[$0] }
                : usage
            let progress: Int64 = if parentUsage?.codexScanComplete != false {
                -1
            } else {
                parentUsage?.codexTokenIndexAnchor?.indexedBytes
                    ?? parentUsage?.parsedBytes
                    ?? 0
            }
            return ScheduledFile(
                fileURL: fileURL,
                originalIndex: index,
                isBackground: isChild || isParent,
                progress: progress,
                childBeforeParent: isChild)
        }

        let ordered = scheduled.sorted { lhs, rhs in
            if lhs.isBackground != rhs.isBackground { return !lhs.isBackground }
            guard lhs.isBackground else { return lhs.originalIndex < rhs.originalIndex }
            if lhs.progress != rhs.progress { return lhs.progress < rhs.progress }
            if lhs.childBeforeParent != rhs.childBeforeParent { return lhs.childBeforeParent }
            return lhs.originalIndex < rhs.originalIndex
        }
        var foreground = ordered.filter { !$0.isBackground }
        let background = ordered.filter(\.isBackground)
        guard !foreground.isEmpty, !background.isEmpty else {
            return ordered.map(\.fileURL)
        }

        if foreground.count > 1 {
            let cursor = max(0, cache.codexForegroundScheduleCursor ?? 0) % foreground.count
            foreground = Array(foreground[cursor...]) + Array(foreground[..<cursor])
            cache.codexForegroundScheduleCursor = (cursor + 1) % foreground.count
        } else {
            cache.codexForegroundScheduleCursor = 0
        }

        let dependencyFirst = cache.codexDependencyLaneStartsNext ?? false
        cache.codexDependencyLaneStartsNext = !dependencyFirst
        if dependencyFirst {
            return [background[0].fileURL]
                + foreground.map(\.fileURL)
                + background.dropFirst().map(\.fileURL)
        }
        return [foreground[0].fileURL]
            + background.map(\.fileURL)
            + foreground.dropFirst().map(\.fileURL)
    }

    private static func reconcileCodexCachePathAliases(
        metadata: CodexFileMetadata,
        cache: inout CostUsageCache)
    {
        guard let fileID = metadata.fileId else { return }
        var aliases = cache.files.compactMap { path, usage in
            path != metadata.path && usage.codexScanFileId == fileID ? path : nil
        }.sorted()
        guard !aliases.isEmpty else { return }

        if cache.files[metadata.path] == nil, let migratedPath = aliases.first {
            cache.files[metadata.path] = cache.files.removeValue(forKey: migratedPath)
            aliases.removeFirst()
        }
        for alias in aliases {
            guard let stale = cache.files[alias] else { continue }
            Self.applyFileDays(cache: &cache, fileDays: stale.days, sign: -1)
            cache.files.removeValue(forKey: alias)
        }
    }
}

// swiftlint:enable type_body_length
