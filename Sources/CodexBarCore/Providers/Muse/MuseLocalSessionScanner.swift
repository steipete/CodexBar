import Foundation

/// One local-calendar day of Muse session-token activity.
public struct MuseLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let requestCount: Int
    public let models: [String]
    public init(date: String, totalTokens: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, reasoningTokens: Int, requestCount: Int, models: [String]) {
        self.date = date; self.totalTokens = totalTokens; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens; self.reasoningTokens = reasoningTokens; self.requestCount = requestCount; self.models = models
    }
}

public struct MuseLocalSessionSummary: Sendable {
    public let fileCount: Int; public let totalTokens: Int; public let totalInputTokens: Int; public let totalOutputTokens: Int; public let totalCacheReadTokens: Int; public let totalReasoningTokens: Int; public let requestCount: Int; public let lastEventAt: Date?; public let primaryModel: String?; public let models: [String]; public let daily: [MuseLocalDailyBucket]; public let scannedAt: Date
    public init(fileCount: Int, totalTokens: Int, totalInputTokens: Int, totalOutputTokens: Int, totalCacheReadTokens: Int, totalReasoningTokens: Int, requestCount: Int, lastEventAt: Date?, primaryModel: String?, models: [String], daily: [MuseLocalDailyBucket] = [], scannedAt: Date = .init()) {
        self.fileCount = fileCount; self.totalTokens = totalTokens; self.totalInputTokens = totalInputTokens; self.totalOutputTokens = totalOutputTokens; self.totalCacheReadTokens = totalCacheReadTokens; self.totalReasoningTokens = totalReasoningTokens; self.requestCount = requestCount; self.lastEventAt = lastEventAt; self.primaryModel = primaryModel; self.models = models; self.daily = daily; self.scannedAt = scannedAt
    }
    public func toCostUsageTokenSnapshot(historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = self.daily.map { bucket in CostUsageDailyReport.Entry(date: bucket.date, inputTokens: bucket.inputTokens > 0 ? bucket.inputTokens : nil, outputTokens: bucket.outputTokens > 0 ? bucket.outputTokens : nil, cacheReadTokens: bucket.cacheReadTokens > 0 ? bucket.cacheReadTokens : nil, reasoningTokens: bucket.reasoningTokens > 0 ? bucket.reasoningTokens : nil, totalTokens: bucket.totalTokens, requestCount: bucket.requestCount, costUSD: nil, modelsUsed: bucket.models.isEmpty ? nil : bucket.models, modelBreakdowns: nil) }
        guard !entries.isEmpty else { return nil }
        let todayKey = MuseLocalSessionScanner.dayKey(for: self.scannedAt, calendar: .current)
        let todayTokens = todayKey.flatMap { key in self.daily.first { $0.date == key }?.totalTokens }
        let todayRequests = todayKey.flatMap { key in self.daily.first { $0.date == key }?.requestCount }
        return CostUsageTokenSnapshot(sessionTokens: todayTokens, sessionCostUSD: nil, sessionRequests: todayRequests, last30DaysTokens: self.totalTokens, last30DaysCostUSD: nil, last30DaysRequests: self.requestCount, historyDays: historyDays, historyCoverageIsEstablished: true, costProvenance: .unknown, daily: entries, updatedAt: self.scannedAt)
    }
}

public enum MuseLocalSessionScanner {
    public static let defaultLookbackDays = 30
    nonisolated(unsafe) static var test_fileScanObserver: ((URL) -> Void)?
    // MARK: - Public entry points
    public static func summarize(env: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default, lookbackDays: Int = defaultLookbackDays, now: Date = .init(), fileScanObserver: ((URL) -> Void)? = nil) -> MuseLocalSessionSummary {
        // Non-throwing wrapper for tests and sync callers; cancellation is not checked.
        do {
            return try self.summarizeCancellable(env: env, fileManager: fileManager, lookbackDays: lookbackDays, now: now, fileScanObserver: fileScanObserver, checkCancellation: nil)
        } catch {
            // Should never throw when checkCancellation is nil; return empty summary as fallback
            return MuseLocalSessionSummary(fileCount: 0, totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0, totalReasoningTokens: 0, requestCount: 0, lastEventAt: nil, primaryModel: nil, models: [], scannedAt: now)
        }
    }

    static func summarizeCancellable(env: [String: String], fileManager: FileManager, lookbackDays: Int, now: Date, fileScanObserver: ((URL) -> Void)?, checkCancellation: (() throws -> Void)?) throws -> MuseLocalSessionSummary {
        let cacheRoot = self.cacheRootForTesting(env: env, fileManager: fileManager)
        var cache = MuseSessionCostCacheIO.load(cacheRoot: cacheRoot)
        let calendar = Calendar.current
        if cache.timeZoneIdentifier != nil, cache.timeZoneIdentifier != calendar.timeZone.identifier { cache = MuseSessionCostCache(version: cache.version) }
        let lookbackCutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        let scanSinceKey = self.dayKey(for: lookbackCutoff, calendar: calendar) ?? ""
        let scanUntilKey = self.dayKey(for: now, calendar: calendar) ?? ""
        let sessionsRoot = self.sessionsRoot(env: env, fileManager: fileManager)
        let dateDirs = self.relevantDateDirectories(sessionsRoot: sessionsRoot, calendar: calendar, lookbackCutoff: lookbackCutoff, now: now, fileManager: fileManager)
        if dateDirs.isEmpty {
            // Prune old data even when no date dirs exist
            self.pruneExpired(cache: &cache, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey, calendar: calendar)
            // Only save if not cancelled
            try checkCancellation?()
            cache.lastScanUnixMs = Int64(now.timeIntervalSince1970 * 1000)
            MuseSessionCostCacheIO.save(cache: cache, cacheRoot: cacheRoot, calendar: calendar)
            let summary = self.summaryFromCache(cache: cache, calendar: calendar, sinceKey: scanSinceKey, untilKey: scanUntilKey, now: now, fileCount: 0)
            return summary
        }
        var filePathsInScan: Set<String> = []
        for dateDir in dateDirs {
            try checkCancellation?()
            guard let enumerator = fileManager.enumerator(at: dateDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator { guard url.lastPathComponent == "session.jsonl" else { continue }; filePathsInScan.insert(url.path) }
        }
        for path in filePathsInScan.sorted() {
            try checkCancellation?()
            let url = URL(fileURLWithPath: path)
            let attrs = (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtimeMs = Int64(mtime * 1000)
            let cached = cache.files[path]
            if let cached, cached.mtimeUnixMs == mtimeMs, cached.size == size { continue }
            fileScanObserver?(url); self.test_fileScanObserver?(url)
            // Check for append vs replacement via fingerprint
            if let cached, size > cached.size, cached.parsedBytes > 0, cached.parsedBytes <= size {
                // Verify prefix fingerprint to distinguish append from larger replacement.
                // For small files (<4K) any append changes the first-4K hash, so compare only the prefix that was present at cache time.
                let fingerprintMatches: Bool = {
                    guard let cachedFingerprint = cached.prefixFingerprint else { return false } // old cache without fingerprint => force full reparse
                    guard let fullData = try? Data(contentsOf: url) else { return false }
                    let compareLength = min(4096, Int(cached.size))
                    let currentFingerprint = Self.prefixFingerprint(for: fullData, prefixLength: compareLength)
                    return currentFingerprint == cachedFingerprint
                }()
                if fingerprintMatches {
                    let delta = self.parseMuseSessionFileDelta(fileURL: url, startOffset: cached.parsedBytes, calendar: calendar, lookbackCutoff: lookbackCutoff)
                    if !delta.contributions.isEmpty { self.applyContributions(to: &cache.days, contributions: delta.contributions, sign: 1) }
                    let merged = self.mergedContributions(existing: cached.contributions, delta: delta.contributions)
                    let newFingerprint = (try? Data(contentsOf: url)).map { Self.prefixFingerprint(for: $0) }
                    cache.files[path] = MuseSessionFileUsage(mtimeUnixMs: mtimeMs, size: size, parsedBytes: delta.parsedBytes, prefixFingerprint: newFingerprint, contributions: merged, entryCount: cached.entryCount + delta.entryCount)
                    continue
                }
                // Fingerprint mismatch => treat as replacement (fall through to full reparse)
            }
            // Full reparse path (replacement or new file). Parse first to detect incomplete truncated writes.
            let parsed = self.parseMuseSessionFileFull(fileURL: url, calendar: calendar, lookbackCutoff: lookbackCutoff)
            // If file was truncated to an incomplete fragment (no complete JSON, no newline), preserve old contributions
            // until the write completes. This prevents losing already-counted usage when a crash leaves a partial line.
            // ponytail: O(1) check; if file is intentionally truncated to a smaller complete file, parsedBytes == size so we replace.
            if let cached, size < cached.size, parsed.parsedBytes < size, parsed.contributions.isEmpty, parsed.entryCount == 0 {
                // Keep old cache entry and contributions; don't update file metadata yet (will retry next scan)
                continue
            }
            if let cached { self.applyContributions(to: &cache.days, contributions: cached.contributions, sign: -1) }
            let fingerprint = (try? Data(contentsOf: url)).map { Self.prefixFingerprint(for: $0) }
            if !parsed.contributions.isEmpty { self.applyContributions(to: &cache.days, contributions: parsed.contributions, sign: 1) }
            cache.files[path] = MuseSessionFileUsage(mtimeUnixMs: mtimeMs, size: size, parsedBytes: parsed.parsedBytes, prefixFingerprint: fingerprint, contributions: parsed.contributions, entryCount: parsed.entryCount)
        }
        // Handle deletions and aging-out
        var deletedPaths: [String] = []
        for (path, usage) in cache.files {
            try checkCancellation?()
            if filePathsInScan.contains(path) { continue }
            // If file still exists but its date directory is outside current lookback, it will not be in filePathsInScan
            // We prune such files regardless of existence to prevent unbounded growth
            if let dayKey = self.dayKeyFromPath(path, calendar: calendar) {
                if dayKey < scanSinceKey {
                    // Aged out: remove contributions and metadata (already filtered from summary, but clean cache)
                    self.applyContributions(to: &cache.days, contributions: usage.contributions, sign: -1)
                    deletedPaths.append(path)
                    continue
                }
                if dayKey >= scanSinceKey, dayKey <= scanUntilKey {
                    if !fileManager.fileExists(atPath: path) {
                        self.applyContributions(to: &cache.days, contributions: usage.contributions, sign: -1)
                        deletedPaths.append(path)
                    }
                } else {
                    // DayKey outside window but not aged out? (future) Keep for now.
                }
            } else {
                // Path doesn't match expected /sessions/YYYY/MM/DD structure; if not in scan and missing, prune
                if !fileManager.fileExists(atPath: path) {
                    self.applyContributions(to: &cache.days, contributions: usage.contributions, sign: -1)
                    deletedPaths.append(path)
                }
            }
        }
        for path in deletedPaths { cache.files.removeValue(forKey: path) }
        // Prune expired day aggregates (outside window) that may remain from aged-out files or timezone shifts
        self.pruneExpired(cache: &cache, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey, calendar: calendar)
        try checkCancellation?()
        cache.lastScanUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        MuseSessionCostCacheIO.save(cache: cache, cacheRoot: cacheRoot, calendar: calendar)
        let summary = self.summaryFromCache(cache: cache, calendar: calendar, sinceKey: scanSinceKey, untilKey: scanUntilKey, now: now, fileCount: filePathsInScan.count)
        return summary
    }

    private static func pruneExpired(cache: inout MuseSessionCostCache, scanSinceKey: String, scanUntilKey: String, calendar: Calendar) {
        // Remove day aggregates outside the current window
        for day in Array(cache.days.keys) {
            if day < scanSinceKey || day > scanUntilKey {
                cache.days.removeValue(forKey: day)
            }
        }
        // Also prune files whose dayKey is outside window and that were not already removed
        // (keeps cache bounded as years of sessions accumulate)
        for (path, usage) in Array(cache.files) {
            if let dayKey = self.dayKeyFromPath(path, calendar: calendar), dayKey < scanSinceKey {
                // Contributions already pruned from days; just remove file metadata
                // Ensure we don't double-subtract if caller already handled
                if !usage.contributions.isEmpty {
                    // Contributions for this file should already be absent from cache.days after day prune,
                    // but if some remain (e.g., due to earlier bug), subtract
                    self.applyContributions(to: &cache.days, contributions: usage.contributions, sign: -1)
                }
                cache.files.removeValue(forKey: path)
            }
        }
    }

    // Deterministic FNV-1a 64-bit for first 4K prefix
    static func prefixFingerprint(for data: Data, prefixLength: Int? = nil) -> String {
        let len = prefixLength ?? min(4096, data.count)
        let clamped = min(len, data.count)
        var hash: UInt64 = 14695981039346656037
        for i in 0..<clamped {
            hash ^= UInt64(data[i])
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    public static func summarizeOffMainThread(env: [String: String], lookbackDays: Int = defaultLookbackDays, now: Date = .init()) async throws -> MuseLocalSessionSummary {
        try await CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            let summary = try Self.summarizeCancellable(env: env, fileManager: .default, lookbackDays: lookbackDays, now: now, fileScanObserver: nil, checkCancellation: checkCancellation)
            try checkCancellation()
            return summary
        }
    }
    static func sessionsRoot(env: [String: String], fileManager: FileManager) -> URL {
        if let override = env["MUSE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty { return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true) }
        if let override = env["CODEXBAR_MUSE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty { return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true) }
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local", isDirectory: true).appendingPathComponent("share", isDirectory: true).appendingPathComponent("muse", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    }
    static func cacheRootForTesting(env: [String: String], fileManager: FileManager) -> URL? {
        if let museHome = env["MUSE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !museHome.isEmpty { return URL(fileURLWithPath: museHome) }
        if let museHome = env["CODEXBAR_MUSE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !museHome.isEmpty { return URL(fileURLWithPath: museHome) }
        if let museCache = env["MUSE_CACHE_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !museCache.isEmpty { return URL(fileURLWithPath: museCache) }
        return nil
    }
    static func relevantDateDirectories(sessionsRoot: URL, calendar: Calendar, lookbackCutoff: Date, now: Date, fileManager: FileManager) -> [URL] {
        let startDay = calendar.startOfDay(for: lookbackCutoff); let endDay = calendar.startOfDay(for: now); guard startDay <= endDay else { return [] }
        var dirs: [URL] = []; var cursor = startDay
        while cursor <= endDay {
            let comps = calendar.dateComponents([.year, .month, .day], from: cursor)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { break }
            let dir = sessionsRoot.appendingPathComponent(String(format: "%04d", y), isDirectory: true).appendingPathComponent(String(format: "%02d", m), isDirectory: true).appendingPathComponent(String(format: "%02d", d), isDirectory: true)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { dirs.append(dir) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dirs
    }
    struct ParsedEvent { let date: Date; let inputTokens: Int; let outputTokens: Int; let cacheReadTokens: Int; let reasoningTokens: Int; let model: String }
    static func events(in fileURL: URL, fileManager: FileManager) -> [ParsedEvent] {
        var out: [ParsedEvent] = []
        do {
            _ = try CostUsageJsonl.scan(fileURL: fileURL, maxLineBytes: 32*1024, prefixBytes: 16*1024, onLine: { line in
                guard !line.wasTruncated else { return }
                if let event = Self.parseLine(line.bytes) { out.append(event); return }
                for innerData in Self.extractRecordJSONDatas(from: line.bytes) { if let event = Self.parseLine(innerData) { out.append(event) } }
            })
        } catch { return out }
        return out
    }
    static func extractRecordJSONDatas(from data: Data) -> [Data] {
        var results: [Data] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: data.count)
            let fullRange = 0..<bytes.count
            var searchRange = fullRange
            while let innerString = Self.extractStringField([UInt8]("record_json".utf8), from: bytes, in: searchRange) {
                if let range = Self.rangeOfFieldValue(field: [UInt8]("record_json".utf8), bytes: bytes, in: searchRange) { searchRange = range.upperBound..<fullRange.upperBound } else { results.append(Data(innerString.utf8)); break }
                results.append(Data(innerString.utf8))
                if results.count > 8 { break }
            }
        }
        return results
    }
    private static func rangeOfFieldValue(field: [UInt8], bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> Range<Int>? {
        var idx = range.lowerBound
        while idx < range.upperBound {
            guard let keyStart = self.indexOfQuote(from: idx, bytes: bytes, limit: range.upperBound) else { break }
            var keyEnd = keyStart + 1
            while keyEnd < range.upperBound {
                let b = bytes[keyEnd]
                if b == UInt8(ascii: "\\") { keyEnd += 2; continue }
                if b == UInt8(ascii: "\"") { break }
                keyEnd += 1
            }
            guard keyEnd < range.upperBound else { break }
            let keyLen = keyEnd - (keyStart + 1)
            let matches: Bool = (keyLen == field.count) ? self.bytesEqual(bytes: bytes, from: keyStart + 1, field: field) : false
            var afterKey = keyEnd + 1
            self.skipWhitespace(bytes: bytes, idx: &afterKey, limit: range.upperBound)
            if afterKey < range.upperBound, bytes[afterKey] == UInt8(ascii: ":") {
                afterKey += 1; self.skipWhitespace(bytes: bytes, idx: &afterKey, limit: range.upperBound)
                if matches {
                    if afterKey < range.upperBound, bytes[afterKey] == UInt8(ascii: "\"") {
                        var end = afterKey + 1
                        while end < range.upperBound {
                            let b = bytes[end]
                            if b == UInt8(ascii: "\\") { end += 2; continue }
                            if b == UInt8(ascii: "\"") { return afterKey..<(end+1) }
                            end += 1
                        }
                    }
                    return nil
                }
            }
            idx = afterKey
        }
        return nil
    }
    static func parseLine(_ data: Data) -> ParsedEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard text.contains("\"model_completed\"") else { return nil }
        guard text.contains("\"runtime.session\"") else { return nil }
        return data.withUnsafeBytes { raw -> ParsedEvent? in
            guard let base = raw.baseAddress else { return nil }
            let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: data.count)
            let fullRange = 0..<bytes.count
            guard let recordedAt = Self.extractIntField([UInt8]("recorded_at".utf8), from: bytes, in: fullRange),
                  let payloadType = Self.extractStringField([UInt8]("payload_type".utf8), from: bytes, in: fullRange),
                  payloadType == "runtime.session" else { return nil }
            guard let eventKind = Self.extractNestedString(outerField: [UInt8]("event".utf8), innerField: [UInt8]("kind".utf8), from: bytes, in: fullRange), eventKind == "model_completed" else { return nil }
            let input = Self.extractNestedInt(outerField: [UInt8]("usage".utf8), innerField: [UInt8]("input_tokens".utf8), from: bytes, in: fullRange) ?? 0
            let output = Self.extractNestedInt(outerField: [UInt8]("usage".utf8), innerField: [UInt8]("output_tokens".utf8), from: bytes, in: fullRange) ?? 0
            let cached = Self.extractNestedInt(outerField: [UInt8]("usage".utf8), innerField: [UInt8]("cache_read_tokens".utf8), from: bytes, in: fullRange) ?? Self.extractNestedInt(outerField: [UInt8]("usage".utf8), innerField: [UInt8]("cached_tokens".utf8), from: bytes, in: fullRange) ?? 0
            let reasoning = Self.extractNestedInt(outerField: [UInt8]("usage".utf8), innerField: [UInt8]("reasoning_tokens".utf8), from: bytes, in: fullRange) ?? 0
            let model = Self.extractNestedString(outerField: [UInt8]("event".utf8), innerField: [UInt8]("model".utf8), from: bytes, in: fullRange) ?? ""
            let date = Date(timeIntervalSince1970: Double(recordedAt) / 1_000_000.0)
            guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0 else { return nil }
            return ParsedEvent(date: date, inputTokens: max(0, input), outputTokens: max(0, output), cacheReadTokens: max(0, cached), reasoningTokens: max(0, reasoning), model: model.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    private static func extractStringField(_ field: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> String? {
        self.extractField(field, from: bytes, in: range) { idx in self.parseJSONString(at: &idx, bytes: bytes, limit: range.upperBound) }
    }
    private static func extractIntField(_ field: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> Int? {
        self.extractField(field, from: bytes, in: range) { idx in self.parseInt(at: &idx, bytes: bytes, limit: range.upperBound) }
    }
    private static func extractNestedString(outerField: [UInt8], innerField: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> String? {
        guard let outerRange = self.objectRange(for: outerField, from: bytes, in: range) else { return nil }
        return self.extractStringField(innerField, from: bytes, in: outerRange)
    }
    private static func extractNestedInt(outerField: [UInt8], innerField: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> Int? {
        guard let outerRange = self.objectRange(for: outerField, from: bytes, in: range) else { return nil }
        return self.extractIntField(innerField, from: bytes, in: outerRange)
    }
    private static func objectRange(for field: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> Range<Int>? {
        self.extractField(field, from: bytes, in: range) { idx in self.parseObjectRange(at: &idx, bytes: bytes, limit: range.upperBound) }
    }
    private static func extractField<T>(_ field: [UInt8], from bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>, parse: (inout Int) -> T?) -> T? {
        var idx = range.lowerBound
        while idx < range.upperBound {
            guard let keyStart = self.indexOfQuote(from: idx, bytes: bytes, limit: range.upperBound) else { break }
            var keyEnd = keyStart + 1; var hasEscape = false
            while keyEnd < range.upperBound {
                let b = bytes[keyEnd]
                if b == UInt8(ascii: "\\") { hasEscape = true; keyEnd += 2; continue }
                if b == UInt8(ascii: "\"") { break }
                keyEnd += 1
            }
            guard keyEnd < range.upperBound else { break }
            let keyLen = keyEnd - (keyStart + 1)
            let keyMatches: Bool = if hasEscape { self.decodeString(bytes: bytes, from: keyStart + 1, to: keyEnd) == String(bytes: field, encoding: .utf8) } else if keyLen == field.count { self.bytesEqual(bytes: bytes, from: keyStart + 1, field: field) } else { false }
            var afterKey = keyEnd + 1
            self.skipWhitespace(bytes: bytes, idx: &afterKey, limit: range.upperBound)
            if afterKey < range.upperBound, bytes[afterKey] == UInt8(ascii: ":") {
                afterKey += 1; self.skipWhitespace(bytes: bytes, idx: &afterKey, limit: range.upperBound)
                if keyMatches { var valueIdx = afterKey; if let v = parse(&valueIdx) { return v } }
            }
            idx = afterKey
        }
        return nil
    }
    private static func indexOfQuote(from idx: Int, bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> Int? {
        var i = idx
        while i < limit { if bytes[i] == UInt8(ascii: "\"") { return i }; i += 1 }
        return nil
    }
    private static func skipWhitespace(bytes: UnsafeBufferPointer<UInt8>, idx: inout Int, limit: Int) {
        while idx < limit, bytes[idx] == 32 || bytes[idx] == 9 || bytes[idx] == 10 || bytes[idx] == 13 { idx += 1 }
    }
    private static func bytesEqual(bytes: UnsafeBufferPointer<UInt8>, from start: Int, field: [UInt8]) -> Bool {
        for i in 0..<field.count where bytes[start + i] != field[i] { return false }; return true
    }
    private static func decodeString(bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String? {
        var out: [UInt8] = []; out.reserveCapacity(end - start); var i = start
        while i < end {
            let b = bytes[i]
            if b == UInt8(ascii: "\\"), i + 1 < end {
                let n = bytes[i+1]
                switch n {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 2
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 2
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 2
                case UInt8(ascii: "n"): out.append(10); i += 2
                case UInt8(ascii: "t"): out.append(9); i += 2
                default: out.append(b); i += 1
                }
            } else { out.append(b); i += 1 }
        }
        return String(bytes: out, encoding: .utf8)
    }
    private static func parseJSONString(at idx: inout Int, bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> String? {
        guard idx < limit, bytes[idx] == UInt8(ascii: "\"") else { return nil }
        idx += 1; let start = idx; var hasEscape = false
        while idx < limit {
            let b = bytes[idx]
            if b == UInt8(ascii: "\\") { hasEscape = true; idx += 2; continue }
            if b == UInt8(ascii: "\"") {
                let end = idx; idx += 1
                if hasEscape { return self.decodeString(bytes: bytes, from: start, to: end) }
                return String(bytes: bytes[start..<end], encoding: .utf8)
            }
            idx += 1
        }
        return nil
    }
    private static func parseInt(at idx: inout Int, bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> Int? {
        self.skipWhitespace(bytes: bytes, idx: &idx, limit: limit)
        var sign = 1
        if idx < limit, bytes[idx] == UInt8(ascii: "-") { sign = -1; idx += 1 }
        var value = 0; var sawDigit = false
        while idx < limit, bytes[idx] >= 48, bytes[idx] <= 57 {
            sawDigit = true; let d = Int(bytes[idx] - 48)
            let (m, o1) = value.multipliedReportingOverflow(by: 10); if o1 { return nil }
            let (a, o2) = m.addingReportingOverflow(d); if o2 { return nil }
            value = a; idx += 1
        }
        return sawDigit ? sign * value : nil
    }
    private static func parseObjectRange(at idx: inout Int, bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> Range<Int>? {
        guard idx < limit, bytes[idx] == UInt8(ascii: "{") else { return nil }
        let start = idx; var depth = 0; var inString = false; var escape = false
        while idx < limit {
            let b = bytes[idx]
            if inString {
                if escape { escape = false } else if b == UInt8(ascii: "\\") { escape = true } else if b == UInt8(ascii: "\"") { inString = false }
                idx += 1; continue
            }
            if b == UInt8(ascii: "\"") { inString = true; idx += 1; continue }
            if b == UInt8(ascii: "{") { depth += 1 } else if b == UInt8(ascii: "}") { depth -= 1; if depth == 0 { idx += 1; return start..<idx } }
            idx += 1
        }
        return nil
    }
    static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
    // Cache helpers
    private static func applyContributions(to days: inout [String: [String: MusePackedUsage]], contributions: [String: [String: MusePackedUsage]], sign: Int) {
        for (day, modelMap) in contributions { for (model, usage) in modelMap { var dayMap = days[day] ?? [:]; let existing = dayMap[model] ?? MusePackedUsage(); let delta = sign > 0 ? (existing + usage) : (existing - usage); if delta.isZero { dayMap.removeValue(forKey: model) } else { dayMap[model] = delta }; if dayMap.isEmpty { days.removeValue(forKey: day) } else { days[day] = dayMap } } }
    }
    private static func mergedContributions(existing: [String: [String: MusePackedUsage]], delta: [String: [String: MusePackedUsage]]) -> [String: [String: MusePackedUsage]] {
        var result = existing; for (day, modelMap) in delta { for (model, usage) in modelMap { var dayMap = result[day] ?? [:]; let merged = (dayMap[model] ?? MusePackedUsage()) + usage; dayMap[model] = merged; result[day] = dayMap } }; return result
    }
    private static func summaryFromCache(cache: MuseSessionCostCache, calendar: Calendar, sinceKey: String, untilKey: String, now: Date, fileCount: Int) -> MuseLocalSessionSummary {
        var totalTokens = 0; var totalInput = 0; var totalOutput = 0; var totalCacheRead = 0; var totalReasoning = 0; var requestCount = 0; var modelCounts: [String: Int] = [:]; var dailyInput: [String: Int] = [:]; var dailyOutput: [String: Int] = [:]; var dailyCacheRead: [String: Int] = [:]; var dailyReasoning: [String: Int] = [:]; var dailyTokens: [String: Int] = [:]; var dailyRequests: [String: Int] = [:]; var dailyModels: [String: [String: Int]] = [:]; var lastEventAt: Date?
        for (day, modelMap) in cache.days { guard day >= sinceKey, day <= untilKey else { continue }; for (model, usage) in modelMap { totalTokens += usage.totalTokens; totalInput += usage.inputTokens; totalOutput += usage.outputTokens; totalCacheRead += usage.cacheReadTokens; totalReasoning += usage.reasoningTokens; requestCount += usage.requestCount; modelCounts[model, default: 0] += usage.requestCount; dailyInput[day, default: 0] += usage.inputTokens; dailyOutput[day, default: 0] += usage.outputTokens; dailyCacheRead[day, default: 0] += usage.cacheReadTokens; dailyReasoning[day, default: 0] += usage.reasoningTokens; dailyTokens[day, default: 0] += usage.totalTokens; dailyRequests[day, default: 0] += usage.requestCount; dailyModels[day, default: [:]][model, default: 0] += usage.requestCount; if let dayDate = Self.dateFromDayKey(day, calendar: calendar), dayDate > (lastEventAt ?? Date.distantPast) { lastEventAt = dayDate } } }
        if requestCount == 0 { return MuseLocalSessionSummary(fileCount: fileCount, totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0, totalReasoningTokens: 0, requestCount: 0, lastEventAt: nil, primaryModel: nil, models: [], scannedAt: now) }
        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        let daily = dailyTokens.keys.sorted().map { day in let models = (dailyModels[day] ?? [:]).sorted { $0.value > $1.value }.map(\.key); return MuseLocalDailyBucket(date: day, totalTokens: dailyTokens[day] ?? 0, inputTokens: dailyInput[day] ?? 0, outputTokens: dailyOutput[day] ?? 0, cacheReadTokens: dailyCacheRead[day] ?? 0, reasoningTokens: dailyReasoning[day] ?? 0, requestCount: dailyRequests[day] ?? 0, models: models) }
        return MuseLocalSessionSummary(fileCount: fileCount, totalTokens: totalTokens, totalInputTokens: totalInput, totalOutputTokens: totalOutput, totalCacheReadTokens: totalCacheRead, totalReasoningTokens: totalReasoning, requestCount: requestCount, lastEventAt: lastEventAt, primaryModel: sortedModels.first, models: sortedModels, daily: daily, scannedAt: now)
    }
    private static func dayKeyFromPath(_ path: String, calendar: Calendar) -> String? {
        guard let range = path.range(of: "/sessions/") else { return nil }
        let suffix = String(path[range.upperBound...]); let parts = suffix.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        let y = String(parts[0]), m = String(parts[1]), d = String(parts[2])
        guard y.count == 4, m.count == 2, d.count == 2 else { return nil }
        return "\(y)-\(m)-\(d)"
    }
    private static func dateFromDayKey(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        return calendar.date(from: comps)
    }
    private struct MuseParseResult { var contributions: [String: [String: MusePackedUsage]] = [:]; var parsedBytes: Int64 = 0; var entryCount: Int = 0 }
    private static func parseMuseSessionFileFull(fileURL: URL, calendar: Calendar, lookbackCutoff: Date) -> MuseParseResult {
        self.parseMuseSessionFileDelta(fileURL: fileURL, startOffset: 0, calendar: calendar, lookbackCutoff: lookbackCutoff)
    }
    private static func isCompleteJSONFragment(_ data: Data) -> Bool {
        // Check if data, when trimmed, forms a complete JSON object/array.
        // Incomplete trailing writes (e.g., truncated mid-object) will not be valid JSON and will not end with } or ].
        // Complete but irrelevant records (valid JSON) and wrapped records are valid JSON.
        // Complete malformed lines that are valid JSON structure but not Muse (e.g., missing fields) are still valid JSON.
        let trimmed = data.drop(while: { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 })
        guard !trimmed.isEmpty else { return false }
        // Quick check: must end with } or ] after trimming trailing whitespace
        let reversedTrimmed = Data(trimmed.reversed().drop(while: { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }))
        guard let last = reversedTrimmed.first, last == UInt8(ascii: "}") || last == UInt8(ascii: "]") else {
            return false
        }
        // Try JSONSerialization to confirm it's complete valid JSON
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed), options: [.allowFragments])
            return true
        } catch {
            // Even if JSONSerialization fails due to inner malformed content but still ends with } , treat as complete malformed line that should be consumed
            // e.g., "{ not valid json" does NOT end with }, so already returned false above.
            // For cases like '{"a":}' which ends with } but is malformed, we still want to consume it once.
            // If it ends with } but failed to parse, consider it a complete malformed line.
            return true
        }
    }
    private static func parseMuseSessionFileDelta(fileURL: URL, startOffset: Int64, calendar: Calendar, lookbackCutoff: Date) -> MuseParseResult {
        var result = MuseParseResult()
        guard let fullData = try? Data(contentsOf: fileURL) else { return result }
        let fileSize = Int64(fullData.count)
        guard startOffset <= fileSize else { return result }
        let sliceData: Data
        if startOffset > 0 {
            sliceData = fullData.suffix(from: Int(startOffset))
        } else {
            sliceData = fullData
        }
        // Determine parsedBytes using parse validity to distinguish valid final line without newline vs incomplete trailing fragment.
        let lastNewlineOffset: Int? = sliceData.lastIndex(of: 10).map { sliceData.distance(from: sliceData.startIndex, to: $0) }
        let isEndsWithNewline = !sliceData.isEmpty && sliceData.last == 10
        var effectiveData: Data
        var parsedBytes: Int64
        if isEndsWithNewline {
            effectiveData = sliceData
            parsedBytes = fileSize
        } else if let lastNL = lastNewlineOffset {
            let trailing = Data(sliceData.suffix(from: lastNL + 1))
            if trailing.isEmpty {
                effectiveData = sliceData
                parsedBytes = fileSize
            } else if Self.isCompleteJSONFragment(trailing) {
                // Trailing bytes form a complete valid (or complete malformed) JSON record without newline — count it now
                effectiveData = sliceData
                parsedBytes = fileSize
            } else {
                // Incomplete trailing fragment — leave for next scan
                effectiveData = sliceData.prefix(lastNL + 1)
                parsedBytes = startOffset + Int64(lastNL + 1)
            }
        } else {
            // No newline in slice: either single complete line without newline or incomplete single line
            if Self.isCompleteJSONFragment(sliceData) {
                effectiveData = sliceData
                parsedBytes = fileSize
            } else {
                // Incomplete single line — leave for retry
                effectiveData = Data()
                parsedBytes = startOffset
            }
        }
        var didParseAny = false
        let lines = effectiveData.split(separator: 10, omittingEmptySubsequences: false)
        for lineSlice in lines {
            if lineSlice.isEmpty { continue }
            let lineData = Data(lineSlice)
            var events: [ParsedEvent] = []
            if let ev = self.parseLine(lineData) { events.append(ev) } else { for inner in self.extractRecordJSONDatas(from: lineData) { if let ev = self.parseLine(inner) { events.append(ev) } } }
            if !events.isEmpty { didParseAny = true }
            for ev in events {
                guard ev.date >= lookbackCutoff else { continue }
                guard let day = self.dayKey(for: ev.date, calendar: calendar) else { continue }
                let total = ev.inputTokens + ev.outputTokens; guard total > 0 else { continue }
                let packed = MusePackedUsage(inputTokens: ev.inputTokens, cacheReadTokens: ev.cacheReadTokens, outputTokens: ev.outputTokens, reasoningTokens: ev.reasoningTokens, totalTokens: total, requestCount: 1)
                var dayMap = result.contributions[day] ?? [:]
                let existing = dayMap[ev.model] ?? MusePackedUsage()
                dayMap[ev.model] = existing + packed
                result.contributions[day] = dayMap
                result.entryCount += 1
            }
        }
        // For the no-newline single-line case where we left effectiveData empty (incomplete), ensure we don't have didParseAny
        // No further adjustment needed; parsedBytes already set correctly.
        _ = didParseAny
        result.parsedBytes = parsedBytes
        return result
    }
}
