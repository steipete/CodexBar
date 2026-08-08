import Foundation

enum CostUsageCacheIO {
    /// Persistence budgets for the Codex cost cache. The artifact holds one entry per
    /// scanned session file plus per-file detail (rows, turn IDs, token snapshots) and is
    /// decoded and encoded as a single JSON document on every scan, so an unbounded corpus
    /// can otherwise grow it to multiple gigabytes. These bounds mirror the scan-side byte
    /// budgets. In-window entries are only dropped by the last-resort budget trim, which
    /// marks the artifact for catch-up so reports recover on the next refresh.
    static let maxCacheFileBytes: Int = 256 * 1024 * 1024
    static let maxCacheFileEntries: Int = 25000
    /// Artifacts above this size are refused at load time and rebuilt by the bounded
    /// scanner instead of being decoded in one shot. `JSONDecoder` materializes the whole
    /// object graph at roughly an order of magnitude over the artifact size (#2637 traced
    /// multi-GiB `MALLOC_LARGE` spikes to exactly this decode), so the cap stays close to
    /// the save budget: `save` bounds artifacts to `maxCacheFileBytes`, and when protected
    /// entries (resuming sessions, fork parents) cannot be trimmed further it may overshoot
    /// only up to this load cap. Anything above the cap is a legacy or foreign artifact
    /// that is cheaper to rebuild bounded than to decode in one shot.
    static let maxCacheLoadBytes: Int = 320 * 1024 * 1024

    /// Producer keys from older parser hashes whose caches are still valid under the current
    /// delta semantics. #2037 invalidated earlier keys; every rotation since #2632 (append-safe
    /// fork resume, bounded persistence, provider-special-case refactors, catch-up report
    /// calendar normalization) preserved stored totals and cache layout, so all shipped
    /// predecessors back to #2632 remain reusable.
    private static let compatibleCodexProducerKeys: Set<String> = [
        "codex:cu:p1cd29792d9ca2b11",
        "codex:cu:p37aedd661c4272a8",
        "codex:cu:p6c0f1fa950e63467",
        "codex:cu:paa27d287348e79b5",
        "codex:cu:p843ca061c36bbea1",
    ]

    /// Parsing and attribution changes rotate the Codex parser producer key.
    /// Increment this artifact version only when the stored schema or cache layout becomes incompatible.
    private static func artifactVersion(for provider: UsageProvider) -> Int {
        // Provider-specific by design: scanner parser/schema compatibility versions differ by cache producer.
        switch provider {
        case .codex:
            11
        case .claude, .vertexai:
            6
        default:
            1
        }
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let artifactVersion = self.artifactVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(artifactVersion).json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheLoadBytes) -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        // Provider-specific by design: only Codex persistence carries bounded resume/discovery scan state.
        // Only Codex has bounded persistence pruning on save; other providers would be
        // rejected, rebuilt, and written oversized again on every refresh.
        let effectiveMaxBytes = provider == .codex ? maxCacheBytes : Int.max
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        let compatibleProducerKeys = producerKey == nil && provider == .codex
            ? self.compatibleCodexProducerKeys
            : []
        if let decoded = self.loadCache(
            at: url,
            expectedProducerKey: expectedProducerKey,
            compatibleProducerKeys: compatibleProducerKeys,
            maxBytes: effectiveMaxBytes)
        {
            if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
                return CostUsageCache()
            }
            return decoded
        }
        return CostUsageCache()
    }

    static func loadCodexForMigration(
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheLoadBytes) -> CostUsageCodexCacheLoadResult
    {
        let url = self.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
        guard let decoded = self.decodeCache(at: url, maxBytes: maxCacheBytes) else {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }
        if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }

        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: .codex)
        let compatibleProducerKeys = producerKey == nil ? self.compatibleCodexProducerKeys : []
        if decoded.producerKey == expectedProducerKey
            || decoded.producerKey.map(compatibleProducerKeys.contains) == true
        {
            return CostUsageCodexCacheLoadResult(cache: decoded, incompatibleCache: nil)
        }

        // Never reuse parser-dependent offsets or totals from an incompatible producer. The
        // caller may still convert its last visible report into a compact, explicitly stale
        // presentation while the current producer rebuilds from byte zero.
        guard decoded.producerKey != nil else {
            return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: nil)
        }
        return CostUsageCodexCacheLoadResult(cache: CostUsageCache(), incompatibleCache: decoded)
    }

    private static func loadCache(
        at url: URL,
        expectedProducerKey: String?,
        compatibleProducerKeys: Set<String>,
        maxBytes: Int) -> CostUsageCache?
    {
        guard let decoded = self.decodeCache(at: url, maxBytes: maxBytes) else { return nil }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey
                || decoded.producerKey.map(compatibleProducerKeys.contains) == true
            else { return nil }
        }
        return decoded
    }

    private static func decodeCache(at url: URL, maxBytes: Int) -> CostUsageCache? {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard fileSize <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        return decoded
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar = .current,
        requestedScanWindow: (sinceKey: String, untilKey: String)? = nil,
        reportWindow: (sinceKey: String, untilKey: String)? = nil,
        maxCacheBytes: Int = CostUsageCacheIO.maxCacheFileBytes,
        maxCacheEntries: Int = CostUsageCacheIO.maxCacheFileEntries,
        maxCacheLoadBytes: Int = CostUsageCacheIO.maxCacheLoadBytes)
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)
        cache.timeZoneIdentifier = calendar.timeZone.identifier

        if provider == .codex {
            _ = Self.pruneCodexCacheForBudget(
                &cache,
                requestedScanWindow: requestedScanWindow,
                calendar: calendar,
                maxCacheBytes: maxCacheBytes,
                maxCacheEntries: maxCacheEntries,
                previousArtifactBytes: Self.fileSize(at: url))
            // Estimate before materializing the document so a refresh that grew the cache
            // stays bounded even when the previous artifact was within budget.
            if Self.estimatedCodexCacheBytes(cache) > maxCacheBytes {
                Self.pruneCodexCacheForBudget(
                    &cache,
                    requestedScanWindow: requestedScanWindow,
                    calendar: calendar,
                    maxCacheBytes: maxCacheBytes,
                    maxCacheEntries: maxCacheEntries,
                    previousArtifactBytes: nil,
                    force: true)
                _ = Self.trimInWindowEntriesForBudget(
                    &cache,
                    calendar: calendar,
                    maxCacheBytes: maxCacheBytes,
                    reportWindow: reportWindow)
            }
        }

        var data = (try? JSONEncoder().encode(cache)) ?? Data()
        if provider == .codex, data.count > maxCacheBytes {
            // The estimate underestimated the payload; prune again so the artifact stays
            // loadable and the next refresh never hits the load-refusal rebuild loop.
            _ = Self.pruneCodexCacheForBudget(
                &cache,
                requestedScanWindow: requestedScanWindow,
                calendar: calendar,
                maxCacheBytes: maxCacheBytes,
                maxCacheEntries: maxCacheEntries,
                previousArtifactBytes: nil,
                force: true)
            data = (try? JSONEncoder().encode(cache)) ?? Data()
            var iterations = 0
            while data.count > maxCacheBytes, iterations < 4 {
                iterations += 1
                let strippedDetail = Self.stripAllInWindowDetailForBudget(
                    &cache,
                    calendar: calendar,
                    reportWindow: reportWindow)
                let clearedLookback = Self.clearActiveLookbackForBudget(&cache)
                let prunedOrphans = Self.pruneOrphanedDiscovery(&cache, maxCacheBytes: maxCacheBytes)
                guard strippedDetail || clearedLookback || prunedOrphans else { break }
                data = (try? JSONEncoder().encode(cache)) ?? Data()
            }
            // The loop can stall with the payload still above the save budget when every
            // remaining byte belongs to protected entries. That overshoot is bounded by
            // `maxCacheLoadBytes` below; the artifact stays loadable, so the next refresh
            // keeps trimming instead of entering a full-rebuild loop.
        }
        if provider == .codex, data.count > maxCacheLoadBytes {
            // Enforcement could not shrink the payload below what `load` accepts (e.g. the
            // bulk lives in unstrippable resume/buffered state). Persisting it would make
            // every launch decode a multi-GiB document just to refuse it; drop the artifact
            // instead so the bounded scanner rebuilds from scratch.
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: [.atomic])
    }

    // swiftlint:disable function_parameter_count
    /// Bounds the Codex cache artifact when the corpus has outgrown the persistence budget.
    /// The all-time accumulation lives in per-file entries whose usage days fall outside the
    /// current scan window; the current report never reads those entries, and dropping them
    /// (with the same day-aggregate subtraction the scanner uses) keeps the artifact from
    /// growing without limit. Entries that are still resuming or that in-window forks depend
    /// on are preserved so bounded scans and fork baselines keep making progress. Priority
    /// turn IDs outside the window are only consulted for in-window rows, so they are trimmed
    /// to the window as well.
    private static func pruneCodexCacheForBudget(
        _ cache: inout CostUsageCache,
        requestedScanWindow: (sinceKey: String, untilKey: String)?,
        calendar: Calendar,
        maxCacheBytes: Int,
        maxCacheEntries: Int,
        previousArtifactBytes: Int64?,
        force: Bool = false) -> Bool
    {
        // Prune against the active requested scan window (what the current report reads),
        // not the historically widened retained union persisted in the cache.
        let sinceKey = requestedScanWindow?.sinceKey ?? cache.scanSinceKey
        let untilKey = requestedScanWindow?.untilKey ?? cache.scanUntilKey
        guard let sinceKey, let untilKey else { return false }
        let overBudget = force || cache.files.count > maxCacheEntries
            || (previousArtifactBytes ?? 0) > Int64(maxCacheBytes)
        guard overBudget else { return false }

        let outOfWindowCandidates = cache.files.keys.filter { key in
            guard let usage = cache.files[key] else { return false }
            if usage.touchesCodexScanWindow(sinceKey: sinceKey, untilKey: untilKey) { return false }
            if usage.codexScanComplete == false { return false }
            if usage.codexJSONLResumeState != nil { return false }
            if usage.hasBufferedCodexForkRetryLines { return false }
            if Self.isRecentlyActive(usage, calendar: calendar, sinceKey: sinceKey, untilKey: untilKey) {
                return false
            }
            return true
        }
        // Protect parents referenced by entries that survive pruning. A stale child that is
        // removed in this pass must not keep its stale parent alive.
        let survivingKeys = Set(cache.files.keys).subtracting(outOfWindowCandidates)
        let survivingParentIDs: [String] = survivingKeys.compactMap { key in
            guard let usage = cache.files[key] else { return nil }
            if usage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey {
                return nil
            }
            return usage.forkedFromId
        }
        let survivingParentSessionIDs = Set(survivingParentIDs)
        let outOfWindowKeys = outOfWindowCandidates.filter { key in
            guard let sessionId = cache.files[key]?.sessionId else { return true }
            return !survivingParentSessionIDs.contains(sessionId)
        }
        var removedPaths: Set<String> = []
        var removedSessionIDs: Set<String> = []
        for key in outOfWindowKeys {
            guard let old = cache.files.removeValue(forKey: key) else { continue }
            removedPaths.insert(key)
            if let sessionId = old.sessionId {
                removedSessionIDs.insert(sessionId)
            }
            CostUsageScanner.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
        }
        if !removedPaths.isEmpty {
            Self.pruneDiscovery(&cache, removedPaths: removedPaths, removedSessionIDs: removedSessionIDs)
        }
        if !outOfWindowKeys.isEmpty, requestedScanWindow != nil {
            // Entries outside the requested window are gone; narrow persisted coverage so a
            // later refresh does not treat them as in-window again.
            cache.scanSinceKey = requestedScanWindow?.sinceKey ?? cache.scanSinceKey
            cache.scanUntilKey = requestedScanWindow?.untilKey ?? cache.scanUntilKey
        }

        let inWindow: (String) -> Bool = { key in
            CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: key,
                since: sinceKey,
                until: untilKey)
        }
        var trimmedTurnIDs = false
        if let idsByDay = cache.codexPriorityTurnIDsByDay {
            let trimmed = idsByDay.filter { inWindow($0.key) }
            cache.codexPriorityTurnIDsByDay = trimmed.isEmpty ? nil : trimmed
            trimmedTurnIDs = trimmed.count != idsByDay.count
        }
        if let turnKeys = cache.codexPriorityTurnKeys {
            let trimmed = turnKeys.filter { inWindow($0.key) }
            cache.codexPriorityTurnKeys = trimmed.isEmpty ? nil : trimmed
            trimmedTurnIDs = trimmedTurnIDs || trimmed.count != turnKeys.count
        }
        return !outOfWindowKeys.isEmpty || trimmedTurnIDs
    }

    // swiftlint:enable function_parameter_count

    /// Drops the oldest completed in-window entries until the estimated payload fits the
    /// byte budget. This is the last line of defense for window-heavy corpora: dropping
    /// entries (with the same day-aggregate subtraction the scanner uses) keeps the artifact
    /// loadable, so the load cap never rejects what `save` can produce and refreshes cannot
    /// fall into a permanent full-rebuild loop. Dropped in-window files are rediscovered and
    /// rescanned by the bounded scanner on later refreshes.
    private static func trimInWindowEntriesForBudget(
        _ cache: inout CostUsageCache,
        calendar: Calendar,
        maxCacheBytes: Int,
        reportWindow: (sinceKey: String, untilKey: String)?) -> Bool
    {
        guard let sinceKey = cache.scanSinceKey, let untilKey = cache.scanUntilKey else { return false }
        let candidates: [(key: String, usage: CostUsageFileUsage)] = cache.files.compactMap { key, usage in
            let inWindow = usage.touchesCodexScanWindow(sinceKey: sinceKey, untilKey: untilKey)
                || Self.isRecentlyActive(usage, calendar: calendar, sinceKey: sinceKey, untilKey: untilKey)
            guard inWindow else { return nil }
            if usage.codexScanComplete == false { return nil }
            if usage.codexJSONLResumeState != nil { return nil }
            if usage.hasBufferedCodexForkRetryLines { return nil }
            return (key, usage)
        }
        guard !candidates.isEmpty else { return false }
        // Protect parents referenced by entries that survive this trim; a child that is
        // removed here must not keep its stale parent protected. Lineage-only children do
        // not resolve inherited parent totals, so their parents need no protection either.
        let candidateKeys = Set(candidates.map(\.key))
        let survivingParentIDs: [String] = cache.files.compactMap { key, usage in
            if candidateKeys.contains(key) { return nil }
            if usage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey {
                return nil
            }
            return usage.forkedFromId
        }
        let protectedParentIDsExcludingLineageOnly = Set(survivingParentIDs)
        let protected = candidates.filter { candidate in
            guard let sessionId = candidate.usage.sessionId else { return false }
            return protectedParentIDsExcludingLineageOnly.contains(sessionId)
        }
        let droppable = candidates.filter { candidate in
            guard let sessionId = candidate.usage.sessionId else { return true }
            return !protectedParentIDsExcludingLineageOnly.contains(sessionId)
        }
        // Preserve the complete report from the untrimmed cache so catch-up displays full
        // totals instead of the reduced window after a restart.
        let preTrimCache = cache
        let previousReport = cache.codexPreviousReport == nil
            ? Self.previousReportForCatchUp(
                cache: preTrimCache,
                calendar: calendar,
                reportWindow: reportWindow)
            : nil

        // Drop oldest usage first so recent sessions keep their fork-baseline detail.
        let oldestFirst = droppable.sorted { lhs, rhs in
            let lhsDay = lhs.usage.days.keys.min() ?? "9999"
            let rhsDay = rhs.usage.days.keys.min() ?? "9999"
            return lhsDay < rhsDay
        }
        var estimated = Self.estimatedCodexCacheBytes(cache)
        let target = max(1, (maxCacheBytes * 3) / 4)
        var droppedKeys: [String] = []
        for (index, candidate) in oldestFirst.enumerated() where estimated > target {
            // Always keep at least the newest entry so the artifact retains window data even
            // when a single entry alone exceeds the target.
            guard index < oldestFirst.count - 1 else { break }
            droppedKeys.append(candidate.key)
            estimated -= Self.estimatedFileUsageBytes(candidate.usage)
        }
        // A dropped parent may still be required by the newest survivor we keep. Never delete
        // it; compact it instead so the retained child can resolve its fork baseline later.
        var stripped = Self.compactParentsRequiredBySurvivors(
            &cache,
            droppedKeys: &droppedKeys)
        var removedPaths: Set<String> = []
        var removedSessionIDs: Set<String> = []
        for key in droppedKeys {
            guard let old = cache.files.removeValue(forKey: key) else { continue }
            removedPaths.insert(key)
            if let sessionId = old.sessionId {
                removedSessionIDs.insert(sessionId)
            }
            CostUsageScanner.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
        }
        // A protected parent referenced by an incomplete/buffered child cannot be dropped,
        // but its rebuildable detail can still be compacted when it alone exceeds the budget.
        let protectedBySize = protected.sorted { lhs, rhs in
            Self.estimatedFileUsageBytes(lhs.usage) > Self.estimatedFileUsageBytes(rhs.usage)
        }
        for candidate in protectedBySize where estimated > target {
            Self.stripFileUsageDetail(&cache, key: candidate.key)
            stripped = true
            estimated -= Self.estimatedFileUsageBytes(candidate.usage)
        }
        // A sole in-window entry can still exceed the budget alone. Strip its rebuildable
        // detail (keeping identity, day aggregates, totals, and cost data) and force a
        // bounded full re-read, so the persisted artifact always fits the load cap.
        if estimated > target, let survivor = oldestFirst.last {
            Self.stripFileUsageDetail(&cache, key: survivor.key)
            stripped = true
        }
        if !removedPaths.isEmpty {
            Self.pruneDiscovery(&cache, removedPaths: removedPaths, removedSessionIDs: removedSessionIDs)
        }
        if !removedPaths.isEmpty || stripped {
            // Dropped or stripped in-window entries would under-report until the next refresh;
            // mark the cache as needing catch-up so a cold restart re-scans them promptly.
            cache.codexScanCatchUpPending = true
            cache.lastScanUnixMs = 0
            if cache.codexPreviousReport == nil {
                cache.codexPreviousReport = previousReport
            }
        }
        return !droppedKeys.isEmpty || stripped
    }

    /// Compacts (instead of dropping) parents that the entries kept by this trim still
    /// reference, so retained fork children can resolve their baselines on later catch-up.
    private static func compactParentsRequiredBySurvivors(
        _ cache: inout CostUsageCache,
        droppedKeys: inout [String]) -> Bool
    {
        let droppedSet = Set(droppedKeys)
        let survivorsAfterDrop = cache.files.keys.filter { !droppedSet.contains($0) }
        let neededBySurvivors: Set<String> = Set(survivorsAfterDrop.compactMap { key in
            guard let usage = cache.files[key] else { return nil }
            if usage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey {
                return nil
            }
            return usage.forkedFromId
        })
        var compactedAny = false
        for key in droppedKeys where cache.files[key]?.sessionId.map(neededBySurvivors.contains) == true {
            Self.stripFileUsageDetail(&cache, key: key)
            droppedKeys.removeAll { $0 == key }
            compactedAny = true
        }
        return compactedAny
    }

    private static func previousReportForCatchUp(
        cache: CostUsageCache,
        calendar: Calendar,
        reportWindow: (sinceKey: String, untilKey: String)?) -> CostUsageCodexPreviousReport?
    {
        // Preserve the user-facing report window, not the scan bounds (which the scanner
        // pads by one day on each side).
        guard let sinceKey = reportWindow?.sinceKey ?? cache.scanSinceKey,
              let untilKey = reportWindow?.untilKey ?? cache.scanUntilKey,
              let since = CostUsageScanner.parseDayKey(sinceKey, calendar: calendar),
              let until = CostUsageScanner.parseDayKey(untilKey, calendar: calendar)
        else { return nil }
        let range = CostUsageScanner.CostUsageDayRange(
            since: since,
            until: until,
            calendar: calendar)
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        guard var previous = CostUsageCodexPreviousReport(report: report, cache: cache) else {
            return nil
        }
        // Persist the bounds that match the report data (the user report window), not the
        // scan-padded cache bounds, so matching never serves narrower data than requested.
        previous.scanSinceKey = reportWindow?.sinceKey ?? cache.scanSinceKey
        previous.scanUntilKey = reportWindow?.untilKey ?? cache.scanUntilKey
        return previous
    }

    /// Last-resort enforcement for payloads the heuristic estimate underestimated: strips
    /// rebuildable detail from every completed in-window entry (keeping identity, day
    /// aggregates, totals, cost data, and fork metadata) and marks the artifact for
    /// catch-up, so the persisted size always fits the load cap.
    private static func stripAllInWindowDetailForBudget(
        _ cache: inout CostUsageCache,
        calendar: Calendar,
        reportWindow: (sinceKey: String, untilKey: String)?) -> Bool
    {
        guard let sinceKey = cache.scanSinceKey, let untilKey = cache.scanUntilKey else { return false }
        let preStripCache = cache
        var strippedAny = false
        for key in cache.files.keys {
            guard let usage = cache.files[key] else { continue }
            let inWindow = usage.touchesCodexScanWindow(sinceKey: sinceKey, untilKey: untilKey)
                || Self.isRecentlyActive(usage, calendar: calendar, sinceKey: sinceKey, untilKey: untilKey)
            guard inWindow, usage.codexScanComplete != false else { continue }
            Self.stripFileUsageDetail(&cache, key: key)
            strippedAny = true
        }
        if strippedAny {
            cache.codexScanCatchUpPending = true
            cache.lastScanUnixMs = 0
            if cache.codexPreviousReport == nil {
                cache.codexPreviousReport = Self.previousReportForCatchUp(
                    cache: preStripCache,
                    calendar: calendar,
                    reportWindow: reportWindow)
            }
        }
        return strippedAny
    }

    /// Removes discovery records for session files that were pruned from `files` so the
    /// persisted discovery state stays bounded with the artifact.
    private static func pruneDiscovery(
        _ cache: inout CostUsageCache,
        removedPaths: Set<String>,
        removedSessionIDs: Set<String>)
    {
        guard var discovery = cache.codexSessionDiscovery, !removedPaths.isEmpty else { return }
        discovery.filePaths.removeAll { removedPaths.contains($0) }
        discovery.fileStamps = discovery.fileStamps.filter { !removedPaths.contains($0.key) }
        discovery.filePathBySessionId = discovery.filePathBySessionId.filter {
            !removedSessionIDs.contains($0.key)
        }
        discovery.missingSessionIds.removeAll { removedSessionIDs.contains($0) }
        discovery.pendingSessionIds.removeAll { removedSessionIDs.contains($0) }
        if let head = discovery.headScan, removedPaths.contains(head.path) {
            discovery.headScan = nil
        }
        // Cursors may point past the shortened arrays; reset them so the next discovery
        // pass re-enqueues remaining files instead of finishing immediately.
        discovery.nextFileIndex = 0
        discovery.nextDirectoryIndex = 0
        discovery.validationDirectoryIndex = 0
        // A compacted discovery is no longer complete; the scanner re-enqueues current files
        // under its bounded budget instead of trusting stale coverage.
        discovery.isComplete = false
        cache.codexSessionDiscovery = discovery
    }

    /// Strips rebuildable per-file detail from the sole oversized survivor so the artifact
    /// stays within the byte budget. Day aggregates, totals, cost data, identity, and fork
    /// metadata are kept; a zero `parsedBytes` forces a bounded full re-read on the next
    /// refresh so any rebuilt index covers the whole file.
    private static func stripFileUsageDetail(_ cache: inout CostUsageCache, key: String) {
        guard var usage = cache.files[key] else { return }
        usage.codexRows = nil
        usage.codexTurnIDs = nil
        usage.codexTokenSnapshots = nil
        usage.codexTokenCheckpoints = nil
        usage.codexTokenTimestampsMonotonic = nil
        usage.codexTokenIndexAnchor = nil
        usage.seenRawTotals = nil
        usage.hasDivergentTotals = nil
        usage.hasInterleavedTotals = nil
        usage.lastRawTotalsBaseline = nil
        usage.lastRawTotalsWatermark = nil
        usage.parsedBytes = 0
        usage.codexCostCacheComplete = nil
        usage.codexScanComplete = false
        usage.codexScanFileId = nil
        cache.files[key] = usage
    }

    /// Cheap upper-bound-ish estimate of the encoded JSON payload, used to decide whether to
    /// prune before materializing the document. Deliberately conservative per-entry overhead
    /// so the estimate triggers at or before the real byte budget.
    private static func estimatedCodexCacheBytes(_ cache: CostUsageCache) -> Int {
        var bytes = 4096
        bytes += cache.files.count * 160
        for usage in cache.files.values {
            bytes += Self.estimatedFileUsageBytes(usage)
        }
        if let idsByDay = cache.codexPriorityTurnIDsByDay {
            for (day, ids) in idsByDay {
                bytes += day.count + 32 + ids.count * 48
            }
        }
        if let turnKeys = cache.codexPriorityTurnKeys {
            for (key, value) in turnKeys {
                bytes += key.count + value.count + 48
            }
        }
        if let discovery = cache.codexSessionDiscovery {
            bytes += discovery.filePaths.count * 110
            bytes += discovery.fileStamps.count * 100
            bytes += discovery.filePathBySessionId.count * 80
            bytes += discovery.missingSessionIds.count * 48
            bytes += discovery.pendingSessionIds.count * 48
            bytes += discovery.directoryPaths.count * 90
            bytes += discovery.directoryStamps.count * 70
        }
        if let lookback = cache.codexActiveLookbackState {
            bytes += lookback.pendingFilePaths.count * 110
            bytes += lookback.legacyRecursivePendingRootPaths.count * 90
            bytes += lookback.completedRootPaths.count * 90
            bytes += lookback.rootPaths.count * 90
            bytes += lookback.nextDayKeyByRoot.count * 60
        }
        return bytes
    }

    /// Compacts the persisted active-lookback state when it keeps the artifact over budget.
    /// Pending file paths are moved into the discovery queue (so no queued scan work is
    /// lost). Legacy recursive roots are left untouched: the discovery directory queue is
    /// only consumed by fork-parent lookup, not by the ordinary refresh file list, so
    /// migrating them there would silently skip recently modified archived sessions.
    private static func clearActiveLookbackForBudget(_ cache: inout CostUsageCache) -> Bool {
        guard var lookback = cache.codexActiveLookbackState,
              !lookback.pendingFilePaths.isEmpty
        else { return false }
        let pendingPaths = lookback.pendingFilePaths
        if !pendingPaths.isEmpty {
            var discovery = cache.codexSessionDiscovery
            if discovery == nil {
                discovery = CostUsageCodexSessionDiscovery(
                    roots: lookback.rootPaths,
                    generation: nil,
                    directoryStamps: [:],
                    directoryPaths: [],
                    nextDirectoryIndex: 0,
                    filePaths: [],
                    nextFileIndex: 0,
                    fileStamps: [:],
                    headScan: nil,
                    filePathBySessionId: [:],
                    missingSessionIds: [],
                    pendingSessionIds: [],
                    validationDirectoryIndex: 0,
                    isComplete: false)
            }
            var seen = Set(discovery?.filePaths ?? [])
            for path in pendingPaths where !seen.contains(path) {
                discovery?.filePaths.append(path)
                seen.insert(path)
            }
            cache.codexSessionDiscovery = discovery
        }
        lookback.pendingFilePaths = []
        cache.codexActiveLookbackState = lookback
        return true
    }

    /// Removes session-id mappings that point to paths neither in the pending discovery
    /// queue nor in the parsed `files` set, and compacts missing/pending session IDs to the
    /// byte budget. Orphaned mappings come from sessions that were deleted or pruned in an
    /// earlier pass and can dominate the artifact without contributing anything; the pending
    /// path queue itself is left untouched.
    private static func pruneOrphanedDiscovery(
        _ cache: inout CostUsageCache,
        maxCacheBytes: Int) -> Bool
    {
        guard var discovery = cache.codexSessionDiscovery else { return false }
        let knownPaths = Set(cache.files.keys)
        let queuedPaths = Set(discovery.filePaths)
        let before = discovery.filePathBySessionId.count
        discovery.filePathBySessionId = discovery.filePathBySessionId.filter { _, path in
            queuedPaths.contains(path) || knownPaths.contains(path)
        }
        let mappingsChanged = discovery.filePathBySessionId.count != before

        // Compress missing/pending session-ID lists to what the remaining byte budget can
        // hold, sharing one capacity across both lists. They are rediscoverable bookkeeping,
        // not parsed data.
        let idBytes = 48
        let baseEstimate = Self.estimatedCodexCacheBytes(cache)
            - (discovery.missingSessionIds.count + discovery.pendingSessionIds.count) * idBytes
        let keepCount = max(0, (maxCacheBytes - baseEstimate) / idBytes)
        let keepMissing = min(discovery.missingSessionIds.count, keepCount)
        let keepPending = min(discovery.pendingSessionIds.count, max(0, keepCount - keepMissing))
        let missingChanged = discovery.missingSessionIds.count > keepMissing
        if missingChanged {
            discovery.missingSessionIds = Array(discovery.missingSessionIds.prefix(keepMissing))
        }
        let pendingChanged = discovery.pendingSessionIds.count > keepPending
        if pendingChanged {
            discovery.pendingSessionIds = Array(discovery.pendingSessionIds.prefix(keepPending))
        }
        guard mappingsChanged || missingChanged || pendingChanged else { return false }
        cache.codexSessionDiscovery = discovery
        return true
    }

    private static func estimatedFileUsageBytes(_ usage: CostUsageFileUsage) -> Int {
        var bytes = 240
        for (day, models) in usage.days {
            bytes += day.count + 32
            for (model, packed) in models {
                bytes += model.count + 40 + packed.count * 10
            }
        }
        bytes += (usage.codexRows?.count ?? 0) * 140
        bytes += (usage.codexTurnIDs?.count ?? 0) * 56
        bytes += (usage.codexTokenSnapshots?.count ?? 0) * 96
        bytes += (usage.codexTokenCheckpoints?.count ?? 0) * 84
        bytes += (usage.seenRawTotals?.count ?? 0) * 72
        for map in [
            usage.codexCostNanos,
            usage.codexPrioritySurchargeNanos,
            usage.codexStandardCostNanos,
            usage.codexPriorityCostNanos,
        ].compactMap(\.self) {
            for (day, values) in map {
                bytes += day.count + 32 + values.count * 72
            }
        }
        for map in [usage.codexStandardTokens, usage.codexPriorityTokens].compactMap(\.self) {
            for (day, values) in map {
                bytes += day.count + 32 + values.count * 40
            }
        }
        return bytes
    }

    /// A session file whose modification time falls inside the scan window is active even
    /// when it has produced no usage rows yet (e.g. a session started today); dropping it
    /// would make every refresh rediscover and fully parse it.
    private static func isRecentlyActive(
        _ usage: CostUsageFileUsage,
        calendar: Calendar,
        sinceKey: String,
        untilKey: String) -> Bool
    {
        guard usage.mtimeUnixMs > 0 else { return false }
        let scanCalendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        let mtimeDayKey = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(usage.mtimeUnixMs) / 1000),
            calendar: scanCalendar)
        return CostUsageScanner.CostUsageDayRange.isInRange(
            dayKey: mtimeDayKey,
            since: sinceKey,
            until: untilKey)
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func currentProducerKey(
        provider: UsageProvider,
        parserHash: String = CodexParserHash.value) -> String?
    {
        // Provider-specific by design: only the Codex incremental parser persists a producer hash.
        guard provider == .codex else { return nil }
        return "\(provider.rawValue):cu:p\(parserHash)"
    }
}

struct CostUsageCodexCacheLoadResult {
    var cache: CostUsageCache
    var incompatibleCache: CostUsageCache?
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    /// True when the last bounded scan left readable Codex work for a background catch-up pass.
    var codexScanCatchUpPending: Bool?
    var codexScanProcessedBytes: Int64?
    var codexScanTotalBytes: Int64?
    var codexScanCompletedFiles: Int?
    var codexScanTotalFiles: Int?
    /// Last user-visible report retained only while an incompatible or forced rebuild catches up.
    var codexPreviousReport: CostUsageCodexPreviousReport?
    /// Persistent session-id discovery and generation-scoped negative lookups for fork parents.
    var codexSessionDiscovery: CostUsageCodexSessionDiscovery?
    /// Resumable bounded discovery for recently modified rollouts in older date partitions.
    var codexActiveLookbackState: CostUsageCodexActiveLookbackState?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?
}

struct CostUsageCodexActiveLookbackState: Codable {
    var scanSinceKey: String
    var rootPaths: [String]
    var nextDayKeyByRoot: [String: String] = [:]
    var completedRootPaths: [String] = []
    var pendingFilePaths: [String] = []
    var legacyRecursivePendingRootPaths: [String] = []
}

struct CostUsageCodexSessionDiscovery: Codable {
    struct DirectoryStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var jsonlFileCount: Int
    }

    struct FileStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var size: Int64
        var fileId: String?
    }

    struct HeadScan: Codable {
        var path: String
        var offset: Int64
        var resumeState: CostUsageJsonl.ResumeState?
    }

    var roots: [String]
    var generation: String?
    var directoryStamps: [String: DirectoryStamp]
    var directoryPaths: [String]
    var nextDirectoryIndex: Int
    var filePaths: [String]
    var nextFileIndex: Int
    var fileStamps: [String: FileStamp]
    var headScan: HeadScan?
    var filePathBySessionId: [String: String]
    var missingSessionIds: [String]
    var pendingSessionIds: [String]
    var validationDirectoryIndex: Int
    var isComplete: Bool
}

struct CostUsageCodexPreviousReport: Codable, Equatable {
    struct ModelBreakdown: Codable, Equatable {
        var modelName: String
        var costUSD: Double?
        var totalTokens: Int?
        var requestCount: Int?
        var standardCostUSD: Double?
        var priorityCostUSD: Double?
        var standardTokens: Int?
        var priorityTokens: Int?

        init(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            self.modelName = breakdown.modelName
            self.costUSD = breakdown.costUSD
            self.totalTokens = breakdown.totalTokens
            self.requestCount = breakdown.requestCount
            self.standardCostUSD = breakdown.standardCostUSD
            self.priorityCostUSD = breakdown.priorityCostUSD
            self.standardTokens = breakdown.standardTokens
            self.priorityTokens = breakdown.priorityTokens
        }

        var dailyReportValue: CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: self.modelName,
                costUSD: self.costUSD,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                standardCostUSD: self.standardCostUSD,
                priorityCostUSD: self.priorityCostUSD,
                standardTokens: self.standardTokens,
                priorityTokens: self.priorityTokens)
        }
    }

    struct Entry: Codable, Equatable {
        var date: String
        var inputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var requestCount: Int?
        var costUSD: Double?
        var modelsUsed: [String]?
        var modelBreakdowns: [ModelBreakdown]?

        init(_ entry: CostUsageDailyReport.Entry) {
            self.date = entry.date
            self.inputTokens = entry.inputTokens
            self.cacheReadTokens = entry.cacheReadTokens
            self.cacheCreationTokens = entry.cacheCreationTokens
            self.outputTokens = entry.outputTokens
            self.totalTokens = entry.totalTokens
            self.requestCount = entry.requestCount
            self.costUSD = entry.costUSD
            self.modelsUsed = entry.modelsUsed
            self.modelBreakdowns = entry.modelBreakdowns?.map(ModelBreakdown.init)
        }

        var dailyReportValue: CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: self.date,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelsUsed: self.modelsUsed,
                modelBreakdowns: self.modelBreakdowns?.map(\.dailyReportValue))
        }
    }

    struct Summary: Codable, Equatable {
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var totalTokens: Int?
        var totalCostUSD: Double?

        init(_ summary: CostUsageDailyReport.Summary) {
            self.totalInputTokens = summary.totalInputTokens
            self.totalOutputTokens = summary.totalOutputTokens
            self.cacheReadTokens = summary.cacheReadTokens
            self.cacheCreationTokens = summary.cacheCreationTokens
            self.totalTokens = summary.totalTokens
            self.totalCostUSD = summary.totalCostUSD
        }

        var dailyReportValue: CostUsageDailyReport.Summary {
            CostUsageDailyReport.Summary(
                totalInputTokens: self.totalInputTokens,
                totalOutputTokens: self.totalOutputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                totalCostUSD: self.totalCostUSD)
        }
    }

    var data: [Entry]
    var summary: Summary?
    var updatedAtUnixMs: Int64
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var roots: [String: Int64]?

    init?(
        report: CostUsageDailyReport,
        cache: CostUsageCache)
    {
        guard !report.data.isEmpty else { return nil }
        self.data = report.data.map(Entry.init)
        self.summary = report.summary.map(Summary.init)
        self.updatedAtUnixMs = cache.lastScanUnixMs
        self.scanSinceKey = cache.scanSinceKey
        self.scanUntilKey = cache.scanUntilKey
        self.timeZoneIdentifier = cache.timeZoneIdentifier
        self.roots = cache.roots
    }

    var report: CostUsageDailyReport {
        CostUsageDailyReport(
            data: self.data.map(\.dailyReportValue),
            summary: self.summary?.dailyReportValue)
    }

    var updatedAt: Date? {
        guard self.updatedAtUnixMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(self.updatedAtUnixMs) / 1000)
    }

    func matches(
        scanSinceKey: String,
        scanUntilKey: String,
        timeZoneIdentifier: String,
        roots: [String: Int64]) -> Bool
    {
        guard self.timeZoneIdentifier == timeZoneIdentifier,
              self.roots == roots,
              let cachedSince = self.scanSinceKey,
              let cachedUntil = self.scanUntilKey
        else { return false }
        return scanSinceKey >= cachedSince && scanUntilKey <= cachedUntil
    }
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var lastRawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]?
    var hasDivergentTotals: Bool?
    var hasInterleavedTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var forkBaselineDependencyKey: String?
    var projectPath: String?
    var canonicalProjectPath: String?
    var codexCostCacheComplete: Bool?
    var codexSession: CostUsageCodexSessionMetadata?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    /// Refreshed by Codex normalization paths, never by sidecar cache validation.
    var codexWorkspaceContentFingerprint: String?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    /// Compact token events used to resolve fork baselines without rereading an entire parent rollout.
    var codexTokenSnapshots: [CostUsageCodexTokenSnapshot]?
    /// Sparse accumulator states for bounded lookup inside `codexTokenSnapshots`.
    var codexTokenCheckpoints: [CostUsageCodexTokenCheckpoint]?
    /// Allows binary-search and early-stop lookup only when event timestamps follow file order.
    var codexTokenTimestampsMonotonic: Bool?
    /// Validates that the indexed JSONL prefix was not rewritten before an append.
    var codexTokenIndexAnchor: CostUsageCodexTokenIndexAnchor?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    /// Identity and latest observed size for an in-progress bounded Codex parse.
    var codexScanFileId: String?
    var codexScanTargetSize: Int64?
    var codexScanComplete: Bool?
    var codexJSONLResumeState: CostUsageJsonl.ResumeState?
    /// Compact relevant events retained while a subagent rollout awaits full-shape classification.
    var codexBufferedSubagentLines: [CostUsageScanner.CodexBufferedFastLine]?
    /// Parsed events retained when an ordinary fork is waiting for its parent baseline.
    var codexBufferedUnresolvedForkLines: [CostUsageScanner.CodexBufferedFastLine]?

    var hasBufferedCodexForkRetryLines: Bool {
        self.codexBufferedSubagentLines?.isEmpty == false
            || self.codexBufferedUnresolvedForkLines?.isEmpty == false
    }
}

struct CostUsageCodexSessionMetadata: Codable, Equatable {
    var sessionId: String?
    var forkedFromId: String?
    var cwd: String?
    var title: String?
    var startedAtUnixMs: Int64?
    var latestActivityUnixMs: Int64?

    var isEmpty: Bool {
        self.sessionId == nil
            && self.forkedFromId == nil
            && self.cwd == nil
            && self.title == nil
            && self.startedAtUnixMs == nil
            && self.latestActivityUnixMs == nil
    }

    func merging(_ newer: CostUsageCodexSessionMetadata) -> CostUsageCodexSessionMetadata {
        CostUsageCodexSessionMetadata(
            sessionId: newer.sessionId ?? self.sessionId,
            forkedFromId: newer.forkedFromId ?? self.forkedFromId,
            cwd: newer.cwd ?? self.cwd,
            title: newer.title ?? self.title,
            startedAtUnixMs: Self.earlier(self.startedAtUnixMs, newer.startedAtUnixMs),
            latestActivityUnixMs: Self.later(self.latestActivityUnixMs, newer.latestActivityUnixMs))
    }

    private static func earlier(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func later(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int?

    init(input: Int, cached: Int, output: Int, reasoning: Int? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
    }
}

struct CostUsageCodexTokenSnapshot: Codable, Equatable {
    var timestamp: String
    var last: CostUsageCodexTotals?
    var total: CostUsageCodexTotals?
    var endOffset: Int64?

    init(
        timestamp: String,
        last: CostUsageCodexTotals?,
        total: CostUsageCodexTotals?,
        endOffset: Int64? = nil)
    {
        self.timestamp = timestamp
        self.last = last
        self.total = total
        self.endOffset = endOffset
    }
}

struct CostUsageCodexTokenAccumulatorState: Codable, Equatable {
    var countedTotals: CostUsageCodexTotals?
    var rawTotalsBaseline: CostUsageCodexTotals?
    var sawDivergentTotals: Bool
    var rawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]
    var sawInterleavedTotals: Bool
}

struct CostUsageCodexTokenCheckpoint: Codable, Equatable {
    /// Index of the last token event already folded into `state`.
    var eventIndex: Int
    var timestamp: String
    var endOffset: Int64
    var state: CostUsageCodexTokenAccumulatorState
}

struct CostUsageCodexTokenIndexAnchor: Codable, Equatable {
    var indexedBytes: Int64
    var windowStart: Int64
    var sha256: String
}
