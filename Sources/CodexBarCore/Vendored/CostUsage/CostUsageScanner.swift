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

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var codexTraceDatabaseURL: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
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
        let projectPath: String?
        let rows: [CodexUsageRow]
    }

    struct CodexUsageRow: Codable, Equatable {
        let day: String
        let model: String
        let turnID: String?
        let eventIndex: Int?
        let input: Int
        let cached: Int
        let output: Int
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
            output: lhs.output + rhs.output)
    }

    private static func codexMinTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: min(lhs.input, rhs.input),
            cached: min(lhs.cached, rhs.cached),
            output: min(lhs.output, rhs.output))
    }

    private static func codexTotalDelta(
        from baseline: CostUsageCodexTotals?,
        to current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let baseline = baseline ?? .init(input: 0, cached: 0, output: 0)
        return CostUsageCodexTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output))
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
            output: delta(raw: rawBaseline.output, counted: countedBaseline.output, current: current.output))
    }

    private static func codexMaxTotals(
        _ lhs: CostUsageCodexTotals?,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        guard let lhs else { return rhs }
        return CostUsageCodexTotals(
            input: max(lhs.input, rhs.input),
            cached: max(lhs.cached, rhs.cached),
            output: max(lhs.output, rhs.output))
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
            output: component(water: watermark.output, counted: counted.output, current: current.output))
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
            self.seenRawTotals.contains(totals)
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
            if !self.seenRawTotals.contains(totals) {
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
    private struct CodexSnapshotAccumulator {
        var countedTotals: CostUsageCodexTotals?
        var rawTotalsBaseline: CostUsageCodexTotals?
        var sawDivergentTotals = false
        var tracker = CodexTotalsTracker()

        /// Applies one token-count event and returns the counted cumulative totals afterwards.
        mutating func apply(
            last: CostUsageCodexTotals?,
            total: CostUsageCodexTotals?) -> CostUsageCodexTotals
        {
            let base = self.countedTotals ?? .init(input: 0, cached: 0, output: 0)
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
    }

    final class CodexCanonicalProjectPathResolver {
        private var cache: [String: String] = [:]
        private let homeCodexWorktreesPrefix: String

        init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
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
        private let files: [URL]
        private let filePaths: Set<String>
        private let roots: [URL]
        private let checkCancellation: CancellationCheck?
        private var nextUnindexedFile = 0
        private var didIndexRoots = false
        private var fileURLBySessionId: [String: URL] = [:]
        private var missingSessionIds: Set<String> = []

        init(
            files: [URL],
            roots: [URL],
            cachedSessionFiles: [String: URL] = [:],
            checkCancellation: CancellationCheck? = nil)
        {
            self.files = files
            self.filePaths = Set(files.map(\.path))
            self.roots = roots
            self.fileURLBySessionId = cachedSessionFiles
            self.checkCancellation = checkCancellation
        }

        func remember(fileURL: URL, sessionId: String?) {
            guard let sessionId, !sessionId.isEmpty else { return }
            self.fileURLBySessionId[sessionId] = fileURL
        }

        func fileURL(for sessionId: String) throws -> URL? {
            if let cached = self.fileURLBySessionId[sessionId] {
                return cached
            }
            if self.missingSessionIds.contains(sessionId) {
                return nil
            }

            while self.nextUnindexedFile < self.files.count {
                try self.checkCancellation?()
                let fileURL = self.files[self.nextUnindexedFile]
                self.nextUnindexedFile += 1
                guard let indexedSessionId = try CostUsageScanner.parseCodexSessionIdentifier(
                    fileURL: fileURL,
                    checkCancellation: self.checkCancellation)
                else {
                    continue
                }
                self.fileURLBySessionId[indexedSessionId] = fileURL
                if indexedSessionId == sessionId {
                    return fileURL
                }
            }

            if !self.didIndexRoots {
                try self.indexRoots()
                if let indexed = self.fileURLBySessionId[sessionId] {
                    return indexed
                }
            }

            self.missingSessionIds.insert(sessionId)
            return nil
        }

        private func indexRoots() throws {
            self.didIndexRoots = true
            guard !self.roots.isEmpty else { return }
            for root in self.roots {
                try self.checkCancellation?()
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    try self.checkCancellation?()
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    guard !self.filePaths.contains(fileURL.path) else { continue }
                    guard let indexedSessionId = try CostUsageScanner.parseCodexSessionIdentifier(
                        fileURL: fileURL,
                        checkCancellation: self.checkCancellation)
                    else {
                        continue
                    }
                    self.fileURLBySessionId[indexedSessionId] = fileURL
                }
            }
        }
    }

    final class CodexInheritedTotalsResolver {
        private struct SnapshotResolution {
            let dependencyKey: String?
            let snapshots: [CodexTimestampedTotals]?
        }

        private let fileIndex: CodexSessionFileIndex
        private let checkCancellation: CancellationCheck?
        private var snapshotResolutions: [String: SnapshotResolution] = [:]

        init(fileIndex: CodexSessionFileIndex, checkCancellation: CancellationCheck?) {
            self.fileIndex = fileIndex
            self.checkCancellation = checkCancellation
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
            guard let snapshots = try self.snapshotResolution(for: sessionId).snapshots else { return .unresolved }
            var inherited: CostUsageCodexTotals?
            for snapshot in snapshots {
                let isAtOrBefore: Bool = if let snapshotDate = snapshot.date, let cutoffDate {
                    snapshotDate <= cutoffDate
                } else {
                    snapshot.timestamp <= cutoffTimestamp
                }
                if isAtOrBefore {
                    inherited = snapshot.totals
                }
            }
            return .resolved(inherited)
        }

        func currentDependencyKey(for sessionId: String) throws -> String {
            guard let fileURL = try self.fileIndex.fileURL(for: sessionId) else {
                return "missing:\(sessionId)"
            }
            return self.dependencyKey(for: sessionId, fileURL: fileURL)
        }

        func dependencyKeyUsed(for sessionId: String) -> String? {
            self.snapshotResolutions[sessionId]?.dependencyKey
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
            guard let fileURL = try self.fileIndex.fileURL(for: sessionId) else {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session file not found",
                    metadata: ["sessionId": sessionId])
                let resolution = SnapshotResolution(
                    dependencyKey: "missing:\(sessionId)",
                    snapshots: nil)
                self.snapshotResolutions[sessionId] = resolution
                return resolution
            }

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
                        snapshots: nil)
                    self.snapshotResolutions[sessionId] = resolution
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
                        snapshots: nil)
                    self.snapshotResolutions[sessionId] = resolution
                    return resolution
                }
                let resolution = SnapshotResolution(
                    dependencyKey: dependencyKeyAfterParse,
                    snapshots: parsed.snapshots)
                self.snapshotResolutions[sessionId] = resolution
                return resolution
            }

            CostUsageScanner.log.warning(
                "Codex cost usage parent session changed while reading; deferring inherited baseline",
                metadata: ["sessionId": sessionId, "path": fileURL.path])
            let resolution = SnapshotResolution(dependencyKey: nil, snapshots: nil)
            self.snapshotResolutions[sessionId] = resolution
            return resolution
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
        let range = CostUsageDayRange(since: since, until: until)
        let emptyReport = CostUsageDailyReport(data: [], summary: nil)
        try checkCancellation?()

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
        case .openai, .azureopenai, .zai, .gemini, .antigravity, .cursor, .opencode, .opencodego, .alibaba,
             .alibabatokenplan, .factory,
             .copilot, .devin, .minimax, .manus, .kilo, .kiro, .kimi, .kimik2, .moonshot, .augment, .jetbrains, .amp,
             .ollama, .t3chat, .synthetic, .openrouter, .elevenlabs, .warp, .perplexity, .mimo, .doubao, .sakana,
             .abacus, .mistral, .deepseek, .codebuff, .crof, .windsurf, .zed, .venice, .commandcode, .qoder, .stepfun,
             .bedrock, .grok, .groq, .llmproxy, .litellm, .deepgram, .poe, .chutes, .crossmodel, .clawrouter,
             .sub2api, .wayfinder, .zenmux:
            return emptyReport
        }
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 1970
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
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

    private static func codexSessionsRoots(options: Options) -> [URL] {
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
        includeRecursive: Bool) -> [URL]
    {
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey)
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
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: String]
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
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
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: [String]]
    {
        var out: [String: Set<String>] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            out[dayKey, default: []].insert(turnID)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func codexPriorityDayKey(_ turn: CodexPriorityTurnMetadata) -> String? {
        guard let timestamp = turn.timestamp else { return nil }
        let dayKeyFromEpoch = Int64(timestamp).map {
            CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        return dayKeyFromEpoch ?? self.dayKeyFromTimestamp(timestamp) ?? self.dayKeyFromParsedISO(timestamp)
    }

    private static func codexPriorityTurnKeysChanged(
        old: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
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
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
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
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
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
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
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

    private static func listCodexRecentlyModifiedFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        modifiedSince: Date) -> [URL]
    {
        let lookbackSinceKey = self.dayKey(scanSinceKey, addingDays: -self.codexActiveSessionLookbackDays)
            ?? scanSinceKey
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: lookbackSinceKey,
            scanUntilKey: scanUntilKey)
        let partitionedModified = self.filterRecentlyModified(files: partitioned, modifiedSince: modifiedSince)

        let legacyRecursive = self.listCodexRecentlyModifiedFilesRecursive(root: root, modifiedSince: modifiedSince)
        var seen = Set(partitionedModified.map(\.path))
        var out = partitionedModified
        for fileURL in legacyRecursive where !seen.contains(fileURL.path) {
            seen.insert(fileURL.path)
            out.append(fileURL)
        }
        return out
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

    private static func dayKey(_ dayKey: String, addingDays days: Int) -> String? {
        guard let date = self.parseDayKey(dayKey) else { return nil }
        guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) else { return nil }
        return CostUsageDayRange.dayKey(from: shifted)
    }

    private static func dayKeys(sinceKey: String, untilKey: String) -> [String] {
        guard let since = self.parseDayKey(sinceKey),
              self.parseDayKey(untilKey) != nil
        else { return sinceKey <= untilKey ? [sinceKey] : [] }

        var out: [String] = []
        var cursor = since
        let calendar = Calendar.current
        while CostUsageDayRange.dayKey(from: cursor) <= untilKey {
            out.append(CostUsageDayRange.dayKey(from: cursor))
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

    private static func isWithinCodexRoots(fileURL: URL, roots: [URL]) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            if filePath == rootPath {
                return true
            }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath.hasPrefix(prefix)
        }
    }

    private static func listCodexSessionFilesByDatePartition(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String) -> [URL]
    {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var out: [URL] = []
        var date = Self.parseDayKey(scanSinceKey) ?? Date()
        let untilDate = Self.parseDayKey(scanUntilKey) ?? date

        while date <= untilDate {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
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

            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
        }

        return out
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

    private struct CodexSessionMetadata {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
        let projectPath: String?
        let isSubagentThread: Bool
    }

    private struct CodexTokenCountRecord {
        let timestamp: String
        let model: String?
        let turnID: String?
        let last: CostUsageCodexTotals?
        let total: CostUsageCodexTotals?
    }

    private enum CodexFastLine {
        case sessionMeta(CodexSessionMetadata)
        case turnContext(model: String?)
        case taskStarted(turnID: String?)
        case tokenCount(CodexTokenCountRecord)
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
    private static let codexJSONFieldParentSessionId = Array("parent_session_id".utf8)
    private static let codexJSONFieldParentSessionIdCamel = Array("parentSessionId".utf8)
    private static let codexJSONFieldPayload = Array("payload".utf8)
    private static let codexJSONFieldSource = Array("source".utf8)
    private static let codexJSONFieldSubagent = Array("subagent".utf8)
    private static let codexJSONFieldSessionId = Array("session_id".utf8)
    private static let codexJSONFieldSessionIdCamel = Array("sessionId".utf8)
    private static let codexJSONFieldTimestamp = Array("timestamp".utf8)
    private static let codexJSONFieldTotalTokenUsage = Array("total_token_usage".utf8)
    private static let codexJSONFieldTurnId = Array("turn_id".utf8)
    private static let codexJSONFieldTurnIdCamel = Array("turnId".utf8)
    private static let codexJSONFieldType = Array("type".utf8)
    private static let codexJSONFieldCwd = Array("cwd".utf8)

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
        return CostUsageCodexTotals(input: input, cached: cached, output: output)
    }

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
                    } ?? false))

            case "turn_context":
                guard let payloadRange = Self.extractJSONByteObjectField(
                    Self.codexJSONFieldPayload,
                    from: rawBuffer,
                    in: objectRange,
                    atDepth: 1)
                else { return .turnContext(model: nil) }
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
                return .turnContext(model: model)

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
            isSubagentThread: Self.codexIsSubagentThread(from: payload))
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
                        case .turnContext, .taskStarted:
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
                            CostUsageCodexTotals(
                                input: toInt($0["input_tokens"]),
                                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                                output: toInt($0["output_tokens"]))
                        }
                        let last = (info["last_token_usage"] as? [String: Any]).map {
                            CostUsageCodexTotals(
                                input: max(0, toInt($0["input_tokens"])),
                                cached: max(0, toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"])),
                                output: max(0, toInt($0["output_tokens"])))
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
            projectPath: nil,
            rows: [])
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
        inheritedTotalsResolver: ((String, String) throws -> CodexForkBaseline)? = nil,
        checkCancellation: CancellationCheck? = nil) throws -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var forkedFromId: String?
        var projectPath: String?
        var isSubagentThread = false
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?
        var forkBaselineResolved = false
        var hasUnresolvedForkBaseline = false
        var unresolvedForkTotalWatermark: CostUsageCodexTotals?
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

        func handleSessionMetadata(_ metadata: CodexSessionMetadata) throws {
            if sessionId == nil {
                sessionId = metadata.sessionId
            }
            if forkedFromId == nil {
                forkedFromId = metadata.forkedFromId
            }
            if projectPath == nil {
                projectPath = metadata.projectPath
            }
            isSubagentThread = isSubagentThread || metadata.isSubagentThread
            if let forkedFromId {
                if isSubagentThread {
                    // Codex subagent rollouts own an independent cumulative counter; their parent
                    // identifiers describe lineage, not a token baseline to subtract (#2193).
                    forkBaselineResolved = true
                    inheritedTotals = nil
                    remainingInheritedTotals = nil
                    hasUnresolvedForkBaseline = false
                } else {
                    try resolveForkBaseline(parentSessionId: forkedFromId, forkedAt: metadata.forkTimestamp ?? "")
                }
            }
        }

        // swiftlint:disable:next function_body_length
        func handleTokenCount(_ record: CodexTokenCountRecord) throws {
            guard let dayKey = Self.dayKeyFromTimestamp(record.timestamp) ?? Self.dayKeyFromParsedISO(record.timestamp)
            else { return }

            let model = Self.codexModelEvidence(currentModel)
                ?? Self.codexModelEvidence(record.model)
                ?? CostUsagePricing.codexUnattributedModel
            let total = record.total
            let last = record.last

            var deltaInput = 0
            var deltaCached = 0
            var deltaOutput = 0

            func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                guard var remaining = remainingInheritedTotals else { return rawDelta }

                let adjusted = CostUsageCodexTotals(
                    input: max(0, rawDelta.input - remaining.input),
                    cached: max(0, rawDelta.cached - remaining.cached),
                    output: max(0, rawDelta.output - remaining.output))

                remaining.input = max(0, remaining.input - rawDelta.input)
                remaining.cached = max(0, remaining.cached - rawDelta.cached)
                remaining.output = max(0, remaining.output - rawDelta.output)
                remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                              remaining.output == 0
                {
                    nil
                } else {
                    remaining
                }

                return adjusted
            }

            // Generic fork children are measured against their parent-inherited baseline so every
            // cumulative comparison in this file happens on a single scale. Subagents use their
            // independent counter directly.
            let adjustedTotal: CostUsageCodexTotals? = total.map { rawTotals in
                guard let inheritedTotals, !hasUnresolvedForkBaseline else { return rawTotals }
                return CostUsageCodexTotals(
                    input: max(0, rawTotals.input - inheritedTotals.input),
                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                    output: max(0, rawTotals.output - inheritedTotals.output))
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
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, delta)
                rawTotalsBaseline = rawBaseline
                if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                    sawDivergentTotals = true
                }
            }

            let handledUnresolvedForkTotal = hasUnresolvedForkBaseline && total != nil
            if hasUnresolvedForkBaseline, let total {
                // `unresolvedForkTotalWatermark` is a presence sentinel for "skip the first
                // unresolved-fork totals row"; delta baselines come from the global tracker.
                let currentRawTotals = total
                defer {
                    unresolvedForkTotalWatermark = currentRawTotals
                }
                guard let last,
                      unresolvedForkTotalWatermark != nil
                else {
                    return
                }

                let adjustedDelta = Self.codexMinTotals(
                    last,
                    Self.codexTotalDelta(from: watermarkBaseline, to: currentRawTotals))
                deltaInput = adjustedDelta.input
                deltaCached = adjustedDelta.cached
                deltaOutput = adjustedDelta.output
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                previousTotals = Self.codexAddTotals(prev, adjustedDelta)
                rawTotalsBaseline = previousTotals
            }

            if !handledUnresolvedForkTotal,
               let currentTotals = adjustedTotal,
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
            } else if !handledUnresolvedForkTotal, let last {
                let rawDelta = last
                let hadRemainingInheritedTotals = remainingInheritedTotals != nil
                var adjustedDelta = adjustedLastDelta(rawDelta)
                let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)

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
                    previousTotals = countedTotals
                    rawTotalsBaseline = countedTotals
                    tracker.raiseWatermark(to: countedTotals)
                }
            } else if !handledUnresolvedForkTotal, let currentTotals = adjustedTotal {
                commitDelta(totalsDerivedDelta(to: currentTotals), rawBaseline: currentTotals)
                remainingInheritedTotals = nil
            } else if !handledUnresolvedForkTotal {
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
                    turnID: record.turnID ?? currentTurnID,
                    eventIndex: eventIndex,
                    input: deltaInput,
                    cached: deltaCached,
                    output: deltaOutput))
            }
        }

        func handleFastLine(_ fastLine: CodexFastLine) throws {
            switch fastLine {
            case let .sessionMeta(metadata):
                try handleSessionMetadata(metadata)
            case let .turnContext(model):
                if let model {
                    currentModel = model
                }
            case let .taskStarted(turnID):
                currentTurnID = turnID
            case let .tokenCount(record):
                try handleTokenCount(record)
            }
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        if startOffset == 0,
           let metadata = try Self.parseCodexSessionMetadata(
               fileURL: fileURL,
               checkCancellation: checkCancellation)
        {
            try handleSessionMetadata(metadata)
        }

        var parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    if deferredError != nil {
                        return
                    }
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // `turn_context` can carry very large prompts, but its model usually appears near the start.
                        if let model = Self.extractCodexTurnContextModel(from: line.bytes) {
                            currentModel = model
                        }
                        return
                    }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#),
                       !line.bytes.containsAscii(#""token_count""#),
                       !line.bytes.containsAscii(#""task_started""#)
                    {
                        return
                    }

                    if let fastLine = Self.parseCodexFastLine(line.bytes) {
                        do {
                            try handleFastLine(fastLine)
                        } catch {
                            deferredError = error
                        }
                        return
                    }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }

                        if type == "session_meta" {
                            guard let metadata = Self.codexSessionMetadata(from: obj) else { return }
                            do {
                                try handleSessionMetadata(metadata)
                            } catch {
                                deferredError = error
                            }
                            return
                        }

                        guard let tsText = obj["timestamp"] as? String else { return }
                        guard Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) != nil
                        else { return }

                        if type == "turn_context" {
                            if let payload = obj["payload"] as? [String: Any] {
                                let info = payload["info"] as? [String: Any]
                                if let model = Self.codexTurnContextModel(
                                    payloadModel: payload["model"] as? String,
                                    payloadModelName: payload["model_name"] as? String,
                                    infoModel: info?["model"] as? String,
                                    infoModelName: info?["model_name"] as? String)
                                {
                                    currentModel = model
                                }
                            }
                            return
                        }

                        guard type == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        if (payload["type"] as? String) == "task_started" {
                            currentTurnID = Self.codexTurnID(from: payload)
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
                            CostUsageCodexTotals(
                                input: max(0, toInt(usage["input_tokens"])),
                                cached: max(0, toInt(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])),
                                output: max(0, toInt(usage["output_tokens"])))
                        }

                        let record = CodexTokenCountRecord(
                            timestamp: tsText,
                            model: modelFromInfo,
                            turnID: Self.codexTurnID(from: payload),
                            last: (info?["last_token_usage"] as? [String: Any]).map(tokenTotals),
                            total: (info?["total_token_usage"] as? [String: Any]).map(tokenTotals))
                        do {
                            try handleTokenCount(record)
                        } catch {
                            deferredError = error
                        }
                    }
                })
            if let deferredError {
                throw deferredError
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning session file",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            parsedBytes = startOffset
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
            projectPath: projectPath,
            rows: rows)
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

        let cached = cache.files[metadata.path]

        let input = CodexFileScanInput(fileURL: fileURL, metadata: metadata, cached: cached)
        if try Self.keepCachedCodexFileIfFresh(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        if try Self.appendCodexFileIncrementIfPossible(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        try Self.rescanCodexFile(input: input, context: context, cache: &cache, state: &state)
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
        let priorityTurnKeys = Self.codexPriorityTurnKeys(priorityTurns)
        let priorityTurnIDsByDay = Self.codexPriorityTurnIDsByDay(priorityTurns)
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

    private static func loadCodexDaily(
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = Self.makeCodexRefreshPlan(cache: cache, range: range, now: now, nowMs: nowMs, options: options)

        if plan.shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let cachedSinceKey = cache.scanSinceKey
            let cachedUntilKey = cache.scanUntilKey
            let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
            let coldCacheLookbackStart = Self.parseDayKey(range.scanSinceKey)
                .map { Calendar.current.startOfDay(for: $0) }
            var seenPaths: Set<String> = []
            var files: [URL] = []
            for root in plan.roots {
                let rootFiles = Self.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: range.scanSinceKey,
                    scanUntilKey: range.scanUntilKey,
                    includeRecursive: options.forceRescan)
                for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                    seenPaths.insert(fileURL.path)
                    files.append(fileURL)
                }

                if shouldRunColdCacheLookback, let coldCacheLookbackStart {
                    let recentlyModifiedFiles = Self.listCodexRecentlyModifiedFiles(
                        root: root,
                        scanSinceKey: range.scanSinceKey,
                        scanUntilKey: range.scanUntilKey,
                        modifiedSince: coldCacheLookbackStart)
                    for fileURL in recentlyModifiedFiles.sorted(by: { $0.path < $1.path })
                        where !seenPaths.contains(fileURL.path)
                    {
                        seenPaths.insert(fileURL.path)
                        files.append(fileURL)
                    }
                }
            }

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

            let filePathsInScan = Set(files.map(\.path))
            var scanState = CodexScanState()
            let fileIndex = CodexSessionFileIndex(
                files: files,
                roots: plan.roots,
                cachedSessionFiles: Self.cachedCodexSessionIndex(
                    cache: cache,
                    roots: plan.roots,
                    knownExistingPaths: filePathsInScan),
                checkCancellation: checkCancellation)
            let inheritedResolver = CodexInheritedTotalsResolver(
                fileIndex: fileIndex,
                checkCancellation: checkCancellation)
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
                checkCancellation: checkCancellation)
            for fileURL in files {
                try Self.scanCodexFile(
                    fileURL: fileURL,
                    context: scanContext,
                    cache: &cache,
                    state: &scanState)
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
            CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }

    private static func codexFileScanContext(
        range: CostUsageDayRange,
        options: Options,
        plan: CodexRefreshPlan,
        resources: CodexScanResources,
        checkCancellation: CancellationCheck?) -> CodexFileScanContext
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
            checkCancellation: checkCancellation)
    }
}

// swiftlint:enable type_body_length
