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

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct CodexScanWorkMetrics: Equatable, Sendable {
        var usageRowsProcessed: Int
        var usageRowsRepriced: Int
    }

    final class CodexScanWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var processed = 0
        private var repriced = 0

        func record(processed: Int, repriced: Int) {
            self.lock.lock()
            self.processed += max(0, processed)
            self.repriced += max(0, repriced)
            self.lock.unlock()
        }

        func snapshot() -> CodexScanWorkMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return CodexScanWorkMetrics(
                usageRowsProcessed: self.processed,
                usageRowsRepriced: self.repriced)
        }
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
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
        var codexScanWorkRecorderForTesting: CodexScanWorkRecorder?

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
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

        func admit(workBytes: Int64) -> Admission {
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
            if allowance < work {
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
        let dependsOnParentTotals: Bool
        let projectPath: String?
        let codexSession: CostUsageCodexSessionMetadata
        let rows: [CodexUsageRow]
        let tokenSnapshots: [CostUsageCodexTokenSnapshot]
        let jsonlResumeState: CostUsageJsonl.ResumeState?
        let bufferedSubagentLines: [CodexBufferedFastLine]?
        let bufferedUnresolvedForkLines: [CodexBufferedFastLine]?
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

    /// Extends sparse checkpoints from the persisted terminal accumulator. Only the appended
    /// token events are folded; the already-indexed prefix is never replayed.
    static func appendingCodexTokenCheckpoints(
        _ events: [CostUsageCodexTokenSnapshot],
        to checkpoints: [CostUsageCodexTokenCheckpoint],
        startingEventIndex: Int,
        initialState: CostUsageCodexTokenAccumulatorState) -> [CostUsageCodexTokenCheckpoint]
    {
        guard !events.isEmpty else { return checkpoints }
        var accumulator = CodexSnapshotAccumulator(state: initialState)
        var appended: [CostUsageCodexTokenCheckpoint] = []
        var lastCheckpointOffset = checkpoints.last?.endOffset ?? 0
        for (offset, event) in events.enumerated() {
            _ = accumulator.apply(last: event.last, total: event.total)
            guard let endOffset = event.endOffset else { continue }
            let reachedStride = endOffset - lastCheckpointOffset >= Self.codexTokenCheckpointStride
            let isLastEvent = offset == events.index(before: events.endIndex)
            guard reachedStride || isLastEvent else { continue }
            appended.append(CostUsageCodexTokenCheckpoint(
                eventIndex: startingEventIndex + offset,
                timestamp: event.timestamp,
                endOffset: endOffset,
                state: accumulator.state))
            lastCheckpointOffset = endOffset
        }
        return checkpoints + appended
    }

    static func codexTokenTimestampsAreMonotonic(
        _ events: [CostUsageCodexTokenSnapshot]) -> Bool
    {
        guard events.count > 1 else { return true }
        for (previous, current) in zip(events, events.dropFirst()) {
            let isOrdered: Bool = if let previousDate = Self.dateFromTimestamp(previous.timestamp),
                                     let currentDate = Self.dateFromTimestamp(current.timestamp)
            {
                previousDate <= currentDate
            } else {
                previous.timestamp <= current.timestamp
            }
            if !isOrdered {
                return false
            }
        }
        return true
    }

    struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
        let projectPathResolver: CodexCanonicalProjectPathResolver
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let priorityTurns: [String: CodexPriorityTurnMetadata]
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
        let workRecorder: CodexScanWorkRecorder?
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
                switch try self.validateInventory() {
                case .current:
                    if self.discovery.missingSessionIds.contains(sessionId),
                       let generation = self.discovery.generation
                    {
                        return .missing(dependencyKey: Self.missingDependencyKey(
                            sessionId: sessionId,
                            generation: generation))
                    }
                case .changed:
                    self.discovery = Self.makeFreshDiscovery(
                        roots: self.roots,
                        files: self.files,
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
                self.discovery.filePathBySessionId.removeValue(forKey: sessionId)
                return nil
            }
            return URL(fileURLWithPath: path)
        }

        private func cachedSessionFiles() -> [String: URL] {
            self.discovery.filePathBySessionId.reduce(into: [:]) { result, entry in
                guard FileManager.default.fileExists(atPath: entry.value) else { return }
                result[entry.key] = URL(fileURLWithPath: entry.value)
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
                let generation = self.discovery.generation ?? "unknown"
                return .missing(dependencyKey: Self.missingDependencyKey(
                    sessionId: requestedSessionId,
                    generation: generation))
            }
        }

        private func scanNextFileHead() throws -> Bool {
            let path = self.discovery.filePaths[self.discovery.nextFileIndex]
            let fileURL = URL(fileURLWithPath: path)
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            guard metadata.fileId != nil else {
                self.advancePastHead(path: path, stamp: nil)
                return true
            }

            var head = self.discovery.headScan
            if head?.path != path {
                head = CostUsageCodexSessionDiscovery.HeadScan(path: path, offset: 0, resumeState: nil)
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

            if let sessionId = result.sessionId, !sessionId.isEmpty {
                self.discovery.filePathBySessionId[sessionId] = path
                self.advancePastHead(path: path, stamp: Self.fileStamp(metadata: metadata))
                return true
            }
            if result.isComplete {
                self.advancePastHead(path: path, stamp: Self.fileStamp(metadata: metadata))
                return true
            }

            self.discovery.headScan = CostUsageCodexSessionDiscovery.HeadScan(
                path: path,
                offset: result.committedOffset,
                resumeState: result.resumeState)
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
            self.discovery.isComplete = true
        }

        private func validateInventory() throws -> InventoryValidation {
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
            return .init(mtimeUnixMs: metadata.mtimeUnixMs, size: metadata.size, fileId: metadata.fileId)
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
            let checkpoints: [CostUsageCodexTokenCheckpoint]
            let indexedTimestampsMonotonic: Bool
            let isComplete: Bool

            init(
                dependencyKey: String?,
                snapshots: [CodexTimestampedTotals]? = nil,
                indexedEvents: [CostUsageCodexTokenSnapshot]? = nil,
                checkpoints: [CostUsageCodexTokenCheckpoint] = [],
                indexedTimestampsMonotonic: Bool = false,
                isComplete: Bool)
            {
                self.dependencyKey = dependencyKey
                self.snapshots = snapshots
                self.indexedEvents = indexedEvents
                self.checkpoints = checkpoints
                self.indexedTimestampsMonotonic = indexedTimestampsMonotonic
                self.isComplete = isComplete
            }

            var lastTimestamp: String? {
                self.indexedEvents?.last?.timestamp ?? self.snapshots?.last?.timestamp
            }

            var hasSnapshotSource: Bool {
                self.indexedEvents != nil || self.snapshots != nil
            }
        }

        private let fileIndex: CodexSessionFileIndex
        private let checkCancellation: CancellationCheck?
        private let scanBudget: CodexScanBudget?
        private var cachedFiles: [String: CostUsageFileUsage]
        private var snapshotResolutions: [String: SnapshotResolution] = [:]
        private var resolvedDependencyKeys: [String: String] = [:]
        private var pendingParentFiles: [String: URL] = [:]

        init(
            fileIndex: CodexSessionFileIndex,
            checkCancellation: CancellationCheck?,
            scanBudget: CodexScanBudget? = nil,
            cachedFiles: [String: CostUsageFileUsage] = [:])
        {
            self.fileIndex = fileIndex
            self.checkCancellation = checkCancellation
            self.scanBudget = scanBudget
            self.cachedFiles = cachedFiles
        }

        func updateCachedUsage(fileURL: URL, usage: CostUsageFileUsage?) {
            let path = fileURL.path
            let standardizedPath = fileURL.standardizedFileURL.path
            let previousSessionId = self.cachedFiles[path]?.sessionId
                ?? self.cachedFiles[standardizedPath]?.sessionId
            if let usage {
                self.cachedFiles[path] = usage
                self.cachedFiles[standardizedPath] = usage
            } else {
                self.cachedFiles.removeValue(forKey: path)
                self.cachedFiles.removeValue(forKey: standardizedPath)
            }
            for sessionId in Set([previousSessionId, usage?.sessionId].compactMap(\.self)) {
                self.snapshotResolutions.removeValue(forKey: sessionId)
                self.resolvedDependencyKeys.removeValue(forKey: sessionId)
            }
        }

        func inheritedTotals(for sessionId: String, atOrBefore cutoffTimestamp: String) throws -> CodexForkBaseline {
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
            guard resolution.hasSnapshotSource else { return .unresolved }
            if !resolution.isComplete {
                guard let lastTimestamp = resolution.lastTimestamp else { return .unresolved }
                let lastDate = CostUsageScanner.dateFromTimestamp(lastTimestamp)
                let coversCutoff: Bool = if let lastDate, let cutoffDate {
                    lastDate >= cutoffDate
                } else {
                    lastTimestamp >= cutoffTimestamp
                }
                guard coversCutoff else { return .unresolved }
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

        private func dependencyKey(for sessionId: String, fileURL: URL) -> String {
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            return [
                "file",
                sessionId,
                fileURL.standardizedFileURL.path,
                metadata.fileId ?? "unknown",
                String(metadata.mtimeUnixMs),
                String(metadata.size),
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
                    isComplete: false)
                self.snapshotResolutions[sessionId] = resolution
                self.resolvedDependencyKeys[sessionId] = dependencyKey
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
                self.snapshotResolutions[sessionId] = cachedResolution
                return cachedResolution
            }
            if self.scanBudget != nil {
                // A parent discovered while parsing a child must use the same persistent,
                // resumable scan path as ordinary files. Queue it for this refresh instead of
                // opening it here and bypassing the byte or wall-clock budget.
                self.pendingParentFiles[fileURL.standardizedFileURL.path] = fileURL
                let resolution = SnapshotResolution(
                    dependencyKey: self.dependencyKey(for: sessionId, fileURL: fileURL),
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
            let cachedUsage = self.cachedFiles[fileURL.path] ?? self.cachedFiles[standardizedPath]
            guard let usage = cachedUsage,
                  usage.sessionId == sessionId,
                  usage.codexScanFileId == nil || usage.codexScanFileId == metadata.fileId,
                  let cachedSnapshots = usage.codexTokenSnapshots
            else { return nil }

            let metadataMatches = usage.mtimeUnixMs == metadata.mtimeUnixMs
                && usage.size == metadata.size
            let appendSafePrefixMatches = usage.codexScanFileId == metadata.fileId
                && usage.size <= metadata.size
                && usage.codexTokenIndexAnchor.map {
                    CostUsageScanner.codexTokenIndexAnchorMatches(
                        $0,
                        fileURL: fileURL,
                        metadata: metadata)
                } == true
            guard metadataMatches || appendSafePrefixMatches else { return nil }

            let indexedBytes = usage.codexTokenIndexAnchor?.indexedBytes ?? usage.parsedBytes ?? usage.size
            let coversCurrentFile = usage.codexScanComplete != false
                && indexedBytes >= metadata.size
            return SnapshotResolution(
                dependencyKey: self.dependencyKey(for: sessionId, fileURL: fileURL),
                indexedEvents: cachedSnapshots,
                checkpoints: usage.codexTokenCheckpoints ?? [],
                indexedTimestampsMonotonic: usage.codexTokenTimestampsMonotonic == true,
                isComplete: coversCurrentFile)
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
        cache.files.compactMap { path, usage in
            guard !excludingPaths.contains(path) else { return nil }
            let hasRelevantDay = usage.days.keys.contains {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.scanSinceKey, until: range.scanUntilKey)
            }
            guard hasRelevantDay else { return nil }
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
        cache: CostUsageCache) -> CostUsageCodexActiveLookbackState?
    {
        var state = state
        state.pendingFilePaths.removeAll { path in
            guard FileManager.default.fileExists(atPath: path) else { return true }
            let fileID = Self.codexFileMetadata(fileURL: URL(fileURLWithPath: path)).fileId
            if let fileID {
                return cache.files.values.contains {
                    $0.codexScanFileId == fileID && $0.codexScanComplete == true
                }
            }
            return cache.files[path]?.codexScanComplete == true
        }
        let isComplete = Set(state.completedRootPaths) == Set(state.rootPaths)
            && state.pendingFilePaths.isEmpty
            && state.legacyRecursivePendingRootPaths.isEmpty
        return isComplete ? nil : state
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
        let endOffset: Int64?
        let line: CodexFastLine

        init(lineIndex: Int, ordinal: Int?, endOffset: Int64? = nil, line: CodexFastLine) {
            self.lineIndex = lineIndex
            self.ordinal = ordinal
            self.endOffset = endOffset
            self.line = line
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

    static func parseCodexSessionIdentifier(
        fileURL: URL,
        checkCancellation: CancellationCheck? = nil) throws -> String?
    {
        try self.parseCodexSessionMetadata(fileURL: fileURL, checkCancellation: checkCancellation)?.sessionId
    }

    static let codexSessionMetadataMaxLineBytes = 256 * 1024

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
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            self.log.warning(
                "Codex cost usage failed to open session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }
        defer { try? handle.close() }

        var buffer = Data()
        var discardingOversizedLine = false

        func parseSessionMetadata(from lineData: Data) -> CodexSessionMetadata? {
            guard !lineData.isEmpty else { return nil }
            if case let .sessionMeta(metadata) = Self.parseCodexFastLine(lineData) {
                return metadata
            }
            return autoreleasepool {
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else { return nil }
                return Self.codexSessionMetadata(from: obj)
            }
        }

        do {
            var matchedMetadata: CodexSessionMetadata?
            while true {
                let reachedEOF = try autoreleasepool { () throws -> Bool in
                    guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                        return true
                    }
                    try checkCancellation?()

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
                           let metadata = parseSessionMetadata(from: buffer)
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
                    return matchedMetadata
                }
                if reachedEOF {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while reading session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }

        if !discardingOversizedLine,
           let metadata = parseSessionMetadata(from: buffer)
        {
            return metadata
        }
        return nil
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
            tokenSnapshots: [],
            jsonlResumeState: nil,
            bufferedSubagentLines: nil,
            bufferedUnresolvedForkLines: nil)
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
        initialJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        maxBytesToRead: Int64? = nil,
        shouldStopReading: ((Int64) -> Bool)? = nil,
        inheritedTotalsResolver: ((String, String) throws -> CodexForkBaseline)? = nil,
        checkCancellation: CancellationCheck? = nil) throws -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var forkedFromId: String?
        var projectPath: String?
        var isSubagentThread = false
        var didCaptureLeafMetadata = false
        var forkTimestamp: String?
        var subagentHistoryStartOrdinal: Int?
        var subagentCounterSemantics: CodexSubagentCounterSemantics?
        var usesLocalSubagentBoundary = false
        var candidateBoundaryDependsOnParentTotals = false
        var parentConfirmedLocalBoundary = false
        var suppressUnownedCopiedPrefix = false
        var codexSession = CostUsageCodexSessionMetadata(
            sessionId: nil,
            forkedFromId: nil,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?
        var forkBaselineResolved = false
        var hasUnresolvedForkBaseline = false
        var currentTurnID = initialCodexTurnID
        var codexUsageRowIndex = initialCodexUsageRowIndex
        var rawTotalsBaseline = initialRawTotalsBaseline ?? initialTotals
        var sawDivergentTotals = initialHasDivergentTotals
        var tracker = CodexTotalsTracker(
            watermark: initialRawTotalsWatermark ?? initialRawTotalsBaseline ?? initialTotals,
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
                remainingInheritedTotals = totals
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
            try configureForkAccountingIfReady()
        }

        // swiftlint:disable:next function_body_length
        func handleTokenCount(_ record: CodexTokenCountRecord) throws {
            observeTimestamp(record.timestamp)
            guard let dayKey = Self.dayKeyFromTimestamp(record.timestamp, calendar: range.calendar)
                ?? Self.dayKeyFromParsedISO(record.timestamp, calendar: range.calendar)
            else { return }
            guard !suppressUnownedCopiedPrefix else { return }

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
            if CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            {
                rows.append(CodexUsageRow(
                    day: dayKey,
                    model: normModel,
                    rawModel: model,
                    turnID: record.turnID ?? currentTurnID,
                    eventIndex: eventIndex,
                    timestampUnixMs: unixMilliseconds(from: record.timestamp),
                    input: deltaInput,
                    cached: deltaCached,
                    output: deltaOutput,
                    reasoning: deltaReasoning))
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

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        var pendingSubagentLines = initialBufferedSubagentLines
        var bufferedUnresolvedForkLines = initialBufferedUnresolvedForkLines

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
                pendingSubagentLines = []
            }
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

        func routeFastLine(
            _ fastLine: CodexFastLine,
            lineIndex: Int,
            ordinal: Int?,
            endOffset: Int64) throws
        {
            let bufferedLine = Self.CodexBufferedFastLine(
                lineIndex: lineIndex,
                ordinal: ordinal,
                endOffset: endOffset,
                line: fastLine)
            if case let .tokenCount(record) = fastLine, record.last != nil || record.total != nil {
                tokenSnapshots.append(CostUsageCodexTokenSnapshot(
                    timestamp: record.timestamp,
                    last: record.last,
                    total: record.total,
                    endOffset: endOffset))
            }
            if pendingSubagentLines != nil {
                pendingSubagentLines?.append(bufferedLine)
            } else {
                try processFastLine(fastLine)
                if hasUnresolvedForkBaseline {
                    if bufferedUnresolvedForkLines == nil {
                        bufferedUnresolvedForkLines = []
                    }
                    bufferedUnresolvedForkLines?.append(bufferedLine)
                }
            }
        }

        var parsedBytes: Int64
        let targetSize = Self.codexFileMetadata(fileURL: fileURL).size
        var physicalLineIndex = (initialBufferedSubagentLines?.last?.lineIndex ?? -1) + 1
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
                                    ordinal: nil,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                        }
                        if pendingSubagentLines != nil {
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
                                        ordinal: nil,
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

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }
                        let ordinal = (obj["ordinal"] as? NSNumber)?.intValue

                        if type == "session_meta" {
                            guard let metadata = Self.codexSessionMetadata(from: obj) else { return }
                            do {
                                try routeFastLine(
                                    .sessionMeta(metadata),
                                    lineIndex: lineIndex,
                                    ordinal: ordinal,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                            return
                        }

                        guard let tsText = obj["timestamp"] as? String else { return }
                        guard Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) != nil
                        else { return }

                        if type == "inter_agent_communication_metadata" {
                            let payload = obj["payload"] as? [String: Any]
                            do {
                                try routeFastLine(
                                    .interAgentCommunication(triggerTurn: payload?["trigger_turn"] as? Bool == true),
                                    lineIndex: lineIndex,
                                    ordinal: ordinal,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                            return
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
                            do {
                                try routeFastLine(
                                    .turnContext(metadata),
                                    lineIndex: lineIndex,
                                    ordinal: ordinal,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                            return
                        }

                        guard type == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        if (payload["type"] as? String) == "task_started" {
                            do {
                                try routeFastLine(
                                    .taskStarted(turnID: Self.codexTurnID(from: payload)),
                                    lineIndex: lineIndex,
                                    ordinal: ordinal,
                                    endOffset: line.endOffset)
                            } catch {
                                deferredError = error
                            }
                            return
                        }
                        guard (payload["type"] as? String) == "token_count" else { return }

                        let info = payload["info"] as? [String: Any]
                        let modelFromInfo = Self.codexModelEvidence(info?["model"] as? String)
                            ?? Self.codexModelEvidence(info?["model_name"] as? String)
                            ?? Self.codexModelEvidence(payload["model"] as? String)
                            ?? Self.codexModelEvidence(obj["model"] as? String)

                        func toInt(_ v: Any?) -> Int {
                            if let n = v as? NSNumber {
                                return n.intValue
                            }
                            return 0
                        }

                        func tokenTotals(_ usage: [String: Any]) -> CostUsageCodexTotals {
                            let output = max(0, toInt(usage["output_tokens"]))
                            return CostUsageCodexTotals(
                                input: max(0, toInt(usage["input_tokens"])),
                                cached: max(0, toInt(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])),
                                output: output,
                                reasoning: (usage["reasoning_output_tokens"] as? NSNumber)
                                    .map { min(max(0, $0.intValue), output) })
                        }

                        let record = CodexTokenCountRecord(
                            timestamp: tsText,
                            model: modelFromInfo,
                            turnID: Self.codexTurnID(from: payload),
                            last: (info?["last_token_usage"] as? [String: Any]).map(tokenTotals),
                            total: (info?["total_token_usage"] as? [String: Any]).map(tokenTotals))
                        do {
                            try routeFastLine(
                                .tokenCount(record),
                                lineIndex: lineIndex,
                                ordinal: ordinal,
                                endOffset: line.endOffset)
                        } catch {
                            deferredError = error
                        }
                    }
                })
            parsedBytes = scanProgress.readOffset
            jsonlResumeState = scanProgress.resumeState
            if let deferredError {
                throw deferredError
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
            dependsOnParentTotals: forkedFromId != nil
                && (candidateBoundaryDependsOnParentTotals
                    || (subagentCounterSemantics != .independent && !usesLocalSubagentBoundary)),
            projectPath: projectPath,
            codexSession: codexSession,
            rows: rows,
            tokenSnapshots: tokenSnapshots,
            jsonlResumeState: jsonlResumeState,
            bufferedSubagentLines: parsedBytes < targetSize
                || jsonlResumeState != nil
                || hasUnresolvedForkBaseline
                ? pendingSubagentLines
                : nil,
            bufferedUnresolvedForkLines: hasUnresolvedForkBaseline
                ? bufferedUnresolvedForkLines
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

    private static func scanCodexFile(
        fileURL: URL,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws
    {
        try context.checkCancellation?()
        let metadata = Self.codexFileMetadata(fileURL: fileURL)
        if let fileId = metadata.fileId, state.seenFileIds.contains(fileId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cache.files[metadata.path], cache: &cache)
            return
        }
        Self.reconcileCodexCachePathAliases(metadata: metadata, cache: &cache)

        let cached = cache.files[metadata.path]

        let input = CodexFileScanInput(fileURL: fileURL, metadata: metadata, cached: cached)
        if try Self.keepCachedCodexFileIfFresh(input: input, context: context, cache: &cache, state: &state) {
            return
        }

        let pendingWorkBytes = Self.pendingCodexScanWorkBytes(metadata: metadata, cached: cached)
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
                return
            }
        } else {
            allowedWorkBytes = pendingWorkBytes
        }

        if try Self.appendCodexFileIncrementIfPossible(
            input: input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: allowedWorkBytes)
        {
            context.scanBudget?.consume(workBytes: allowedWorkBytes)
            return
        }
        let fullRescanWorkBytes = max(0, metadata.size)
        let fullRescanAllowedBytes: Int64
        if fullRescanWorkBytes == pendingWorkBytes {
            fullRescanAllowedBytes = allowedWorkBytes
        } else if let budget = context.scanBudget {
            budget.release(workBytes: allowedWorkBytes)
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
            input: input,
            context: context,
            cache: &cache,
            state: &state,
            maxBytesToRead: fullRescanAllowedBytes)
        context.scanBudget?.consume(workBytes: fullRescanAllowedBytes)
    }

    static func pendingCodexScanWorkBytes(metadata: CodexFileMetadata, cached: CostUsageFileUsage?) -> Int64 {
        // Called only after keepCachedCodexFileIfFresh failed. Forced rescans, priority invalidation,
        // and other paths that reread JSONL must still charge the file; the sole zero-work exception
        // is a validated same-size buffered replay.
        guard let cached else { return max(0, metadata.size) }
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
        if metadata.size > cached.size,
           startOffset > 0,
           startOffset <= metadata.size,
           cached.forkedFromId == nil
        {
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
            $0.codexTurnIDs == nil && $0.touchesCodexScanWindow(
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
        range: CostUsageDayRange) -> CostUsageStoreLoad
    {
        CostUsageStoreAccess.load(cacheRoot: options.cacheRoot, calendar: range.calendar)
    }

    private static func codexPreviousReportCandidate(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        plan: CodexRefreshPlan,
        options: Options) -> CostUsageCodexPreviousReport?
    {
        let currentScanIsPending = cache.codexScanCatchUpPending == true
            || cache.files.values.contains { $0.codexScanComplete == false }
            || cache.files.values.contains { $0.hasBufferedCodexForkRetryLines }
        if currentScanIsPending,
           let previous = self.codexPreviousReport(
               cache: cache,
               range: range,
               rootsFingerprint: plan.rootsFingerprint)
        {
            return previous
        }

        let sourceCache: CostUsageCache? = if !currentScanIsPending,
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

    private static func saveCodexCache(
        _ cache: CostUsageCache,
        store: CostUsageStore,
        options: Options,
        range: CostUsageDayRange)
    {
        // The serial scan queue remains the per-process writer boundary. The store actor owns
        // the sole writable connection; app and CLI readers take independent WAL snapshots.
        CostUsageStoreAccess.save(
            store: store,
            cache: cache,
            calendar: range.calendar,
            requestedScanWindow: (sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey),
            reportWindow: (sinceKey: range.sinceKey, untilKey: range.untilKey))
    }

    // swiftlint:disable:next function_body_length
    private static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let loadedCache = Self.loadCodexCache(options: options, range: range)
        var cache = loadedCache.cache
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = Self.makeCodexRefreshPlan(cache: cache, range: range, now: now, nowMs: nowMs, options: options)
        let previousReport = Self.codexPreviousReportCandidate(
            cache: cache,
            range: range,
            plan: plan,
            options: options)

        if plan.shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let cachedSinceKey = cache.scanSinceKey
            let cachedUntilKey = cache.scanUntilKey
            let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
            let coldCacheLookbackStart = Self.localStartOfDay(range.scanSinceKey, calendar: options.calendar)
            let scanBudget = CodexScanBudget(
                maxFileBytes: options.maxCodexSessionFileBytes,
                maxBytesPerRefresh: options.maxCodexScanBytesPerRefresh,
                maxDuration: options.maxCodexScanDurationPerRefresh)
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
            let inheritedResolver = CodexInheritedTotalsResolver(
                fileIndex: fileIndex,
                checkCancellation: checkCancellation,
                scanBudget: scanBudget,
                cachedFiles: cache.files)
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver,
                projectPathResolver: CodexCanonicalProjectPathResolver(),
                modelsDevCatalog: plan.modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                priorityTurns: plan.priorityTurns)
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
            cache.codexActiveLookbackState = Self.finalizedCodexActiveLookbackState(
                activeLookbackState,
                cache: cache)
            if scanBudget.resumedPartialFileCount > 0
                || scanBudget.deferredByBudgetFileCount > 0
                || scanBudget.deferredByTimeBudgetFileCount > 0
            {
                Self.log.info(
                    "Codex cost scan applied work limits",
                    metadata: [
                        "partialFiles": "\(scanBudget.resumedPartialFileCount)",
                        "deferredByBudget": "\(scanBudget.deferredByBudgetFileCount)",
                        "deferredByTime": "\(scanBudget.deferredByTimeBudgetFileCount)",
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
                ? [cachedSinceKey, range.scanSinceKey].compactMap(\.self).min() ?? range.scanSinceKey
                : range.scanSinceKey
            let retainedUntilKey = shouldRetainWiderWindow
                ? [cachedUntilKey, range.scanUntilKey].compactMap(\.self).max() ?? range.scanUntilKey
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
                || scanProgress.completedFiles < scanProgress.totalFiles
                || cache.files.values.contains { $0.codexScanComplete == false }
                || cache.files.values.contains { $0.hasBufferedCodexForkRetryLines }
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
            Self.saveCodexCache(cache, store: loadedCache.store, options: options, range: range)
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
            let parsedBytes = min(
                max(0, metadata.size),
                max(0, usage.parsedBytes ?? (usage.codexScanComplete == false ? 0 : usage.size)))
            processedBytes += parsedBytes
            if usage.codexScanComplete != false,
               parsedBytes >= metadata.size,
               !usage.hasBufferedCodexForkRetryLines
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
        var visitedPaths = Set(files.map(\.standardizedFileURL.path))
        var scannedPaths = Set(files.map(\.path))
        for fileURL in files {
            try Self.scanCodexFile(
                fileURL: fileURL,
                context: context,
                cache: &cache,
                state: &scanState)
            let usage = cache.files[fileURL.path]
            inheritedResolver.updateCachedUsage(fileURL: fileURL, usage: usage)
            if Self.shouldRetryBufferedCodexFork(usage) {
                bufferedForkRetries.append(fileURL)
            }
        }

        // Parents outside the requested history window are discovered only after parsing their
        // children. Scan those dependencies through the same budgeted path and retain their cache
        // entries so later passes can resume instead of restarting from byte zero.
        var dependencyState = CodexScanState()
        while true {
            let pendingParents = inheritedResolver.takePendingParentFiles().filter {
                visitedPaths.insert($0.standardizedFileURL.path).inserted
            }
            guard !pendingParents.isEmpty else { break }
            for fileURL in pendingParents {
                scannedPaths.insert(fileURL.path)
                try Self.scanCodexFile(
                    fileURL: fileURL,
                    context: context,
                    cache: &cache,
                    state: &dependencyState)
                let usage = cache.files[fileURL.path]
                inheritedResolver.updateCachedUsage(fileURL: fileURL, usage: usage)
                if Self.shouldRetryBufferedCodexFork(usage) {
                    bufferedForkRetries.append(fileURL)
                }
            }
        }

        // Newest-first ordering commonly encounters a child before its parent. Once this
        // refresh has indexed the parent, replay the child's compact parsed events in memory;
        // do not reread the JSONL or wait for another refresh.
        var retryState = CodexScanState()
        var retriedPaths: Set<String> = []
        for fileURL in bufferedForkRetries where retriedPaths.insert(fileURL.path).inserted {
            guard Self.shouldRetryBufferedCodexFork(cache.files[fileURL.path]) else { continue }
            try Self.scanCodexFile(
                fileURL: fileURL,
                context: context,
                cache: &cache,
                state: &retryState)
            inheritedResolver.updateCachedUsage(
                fileURL: fileURL,
                usage: cache.files[fileURL.path])
        }
        return scannedPaths
    }

    private static func shouldRetryBufferedCodexFork(_ usage: CostUsageFileUsage?) -> Bool {
        guard let usage else { return false }
        return usage.forkedFromId != nil
            && usage.forkBaselineDependencyKey == nil
            && usage.hasBufferedCodexForkRetryLines
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
                || plan.priorityMetadataChanged || plan.needsProjectMetadataMigration,
            dropDeferredCodexRows: options.forceRescan || plan.pricingChanged || plan.priorityMetadataChanged
                || plan.needsTurnIDCacheMigration,
            requiresTurnIDCache: plan.needsTurnIDCacheMigration,
            changedPriorityTurnIDs: plan.changedPriorityTurnIDs,
            resources: resources,
            checkCancellation: checkCancellation,
            scanBudget: scanBudget,
            workRecorder: options.codexScanWorkRecorderForTesting)
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
