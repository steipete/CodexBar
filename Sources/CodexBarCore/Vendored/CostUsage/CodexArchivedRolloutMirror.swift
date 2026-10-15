#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CZstd
import Foundation

/// Codex archives finished rollouts as `rollout-*.jsonl.zst` and later deletes the plain `.jsonl`.
/// The cost scanner resumes plain JSONL by byte offset, so archived rollouts are decoded into a
/// CodexBar-owned mirror instead: same relative layout as the source root, archive mtime preserved.
/// The mirror only holds rollouts whose plain `.jsonl` sibling is gone, so a rollout is never counted twice.
///
/// Work is split in two so the mirror joins the scanner's existing contracts: `prepare` only lists,
/// prunes and creates mirror roots before roots are fingerprinted; `materialize` decodes under the
/// refresh's `CodexScanBudget` and reports deferred or failed archives as pending catch-up work.
enum CodexArchivedRolloutMirror {
    static let archiveSuffix = ".jsonl.zst"
    /// A corrupt or unwritable archive is retried when it changes, or after this interval.
    static let failedArchiveRetryInterval: TimeInterval = 60 * 60
    private static let rolloutPrefix = "rollout-"
    private static let partialSuffix = ".partial"
    private static let failureLedgerName = ".failed-archives.json"
    /// Same-mtime check for an already mirrored archive; Foundation round-trips through `Double` seconds.
    private static let mtimeTolerance: TimeInterval = 0.01

    struct SyncResult: Equatable {
        var materialized = 0
        var removed = 0
        /// Archives that failed to decode or write, including ones waiting out their retry interval.
        var failed = 0
        /// Archives left for a later refresh by the scan budget.
        var deferred = 0
        var materializedSessionIds: Set<String> = []

        var hasPendingWork: Bool {
            self.failed > 0 || self.deferred > 0
        }
    }

    enum DecodeError: Error, Equatable {
        case decoderUnavailable
        case zstd(String)
        case truncated
    }

    struct Archive {
        let url: URL
        let relativePath: String
        let mirrorURL: URL
        let modified: Date
        let size: Int64
        /// Lowercased session UUID from the rollout filename, used to find archived fork parents.
        let sessionId: String?
        let mirrorModified: Date?

        var mirrorIsCurrent: Bool {
            self.mirrorModified
                .map { abs($0.timeIntervalSince(self.modified)) < CodexArchivedRolloutMirror.mtimeTolerance }
                ?? false
        }
    }

    struct Inventory {
        struct Root {
            let mirrorRoot: URL
            /// Archives whose plain `.jsonl` sibling is absent.
            let archives: [Archive]
        }

        var roots: [Root] = []
        var removed = 0

        /// Archives holding one of `sessionIds` that are not mirrored yet.
        func unmirroredArchiveCount(forSessionIds sessionIds: Set<String>, excluding mirrored: Set<String>) -> Int {
            let wanted = sessionIds.subtracting(mirrored)
            guard !wanted.isEmpty else { return 0 }
            return self.roots.reduce(0) { count, root in
                count + root.archives.count { archive in
                    archive.sessionId.map(wanted.contains) == true && !archive.mirrorIsCurrent
                }
            }
        }
    }

    static func mirrorRoot(for sourceRoot: URL, cacheRoot: URL?) -> URL {
        let base = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        let digest = SHA256.hash(data: Data(sourceRoot.standardizedFileURL.path.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return base
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("codex-archived-rollouts", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// Mirror roots that exist on disk. Absent mirrors stay out of the root set, so installs without
    /// archived rollouts keep their existing root fingerprint.
    static func existingMirrorRoots(for sourceRoots: [URL], cacheRoot: URL?) -> [URL] {
        sourceRoots.compactMap { sourceRoot in
            let mirror = self.mirrorRoot(for: sourceRoot, cacheRoot: cacheRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mirror.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return mirror
        }
    }

    // MARK: - Phases

    /// Lists archives, prunes mirrors whose archive is gone or whose plain `.jsonl` returned, and creates
    /// mirror roots that will be needed, so they are part of this refresh's root set. Decodes nothing.
    static func prepare(
        sourceRoots: [URL],
        cacheRoot: URL?,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Inventory
    {
        var inventory = Inventory()
        for sourceRoot in sourceRoots {
            try checkCancellation?()
            let mirrorRoot = self.mirrorRoot(for: sourceRoot, cacheRoot: cacheRoot)
            let archives = self.archives(under: sourceRoot.standardizedFileURL, mirrorRoot: mirrorRoot)
            inventory.removed += self.pruneMirror(
                mirrorRoot,
                keeping: Set(archives.map(\.mirrorURL.standardizedFileURL.path)))
            if !archives.isEmpty {
                try FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
            }
            inventory.roots.append(.init(mirrorRoot: mirrorRoot, archives: archives))
        }
        return inventory
    }

    /// Decodes archives the scan window can see, plus archived parents named in `requiredSessionIds`
    /// regardless of their age. Newest work runs first; the budget can defer the rest to a later refresh.
    static func materialize(
        _ inventory: Inventory,
        modifiedSince: Date?,
        requiredSessionIds: Set<String> = [],
        budget: CostUsageScanner.CodexScanBudget? = nil,
        now: Date = Date(),
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> SyncResult
    {
        var result = SyncResult()
        result.removed = inventory.removed
        let required = Set(requiredSessionIds.map { $0.lowercased() })
        for root in inventory.roots {
            var ledger = self.loadFailureLedger(mirrorRoot: root.mirrorRoot)
            let originalLedger = ledger
            ledger = ledger.filter { path, _ in root.archives.contains { $0.relativePath == path } }
            let work = root.archives.filter { archive in
                guard !archive.mirrorIsCurrent else { return false }
                if archive.mirrorModified != nil || required.contains(archive.sessionId ?? "") { return true }
                guard let modifiedSince else { return true }
                return archive.modified >= modifiedSince
            }.sorted { lhs, rhs in
                let lhsRequired = required.contains(lhs.sessionId ?? "")
                let rhsRequired = required.contains(rhs.sessionId ?? "")
                if lhsRequired != rhsRequired { return lhsRequired }
                return lhs.modified > rhs.modified
            }
            for (index, archive) in work.enumerated() {
                try checkCancellation?()
                if let failure = ledger[archive.relativePath], failure.matches(archive),
                   now.timeIntervalSince(failure.attemptedAt) < self.failedArchiveRetryInterval
                {
                    result.failed += 1
                    continue
                }
                guard let admitted = self.admit(archive, budget: budget) else {
                    result.deferred += work.count - index
                    break
                }
                do {
                    try self.materialize(archive: archive, checkCancellation: checkCancellation)
                    budget?.complete(admittedWorkBytes: admitted, actualWorkBytes: admitted)
                    ledger[archive.relativePath] = nil
                    result.materialized += 1
                    if let sessionId = archive.sessionId {
                        result.materializedSessionIds.insert(sessionId)
                    }
                } catch {
                    budget?.complete(admittedWorkBytes: admitted, actualWorkBytes: admitted)
                    // Cancellation propagates; anything else is recorded so coverage stays pending.
                    try checkCancellation?()
                    ledger[archive.relativePath] = FailedArchive(archive: archive, attemptedAt: now)
                    result.failed += 1
                }
            }
            if ledger != originalLedger {
                self.saveFailureLedger(ledger, mirrorRoot: root.mirrorRoot)
            }
        }
        return result
    }

    /// Unbudgeted `prepare` + `materialize`, for callers outside a scanner refresh.
    @discardableResult
    static func sync(
        sourceRoots: [URL],
        cacheRoot: URL?,
        modifiedSince: Date?,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> SyncResult
    {
        let inventory = try self.prepare(
            sourceRoots: sourceRoots,
            cacheRoot: cacheRoot,
            checkCancellation: checkCancellation)
        return try self.materialize(inventory, modifiedSince: modifiedSince, checkCancellation: checkCancellation)
    }

    // MARK: - Budget

    /// Returns the admitted work, or nil to defer. Like a partially admitted rollout, the first archive in a
    /// refresh is decoded whole even when it exceeds the remaining budget, so every refresh makes progress.
    private static func admit(_ archive: Archive, budget: CostUsageScanner.CodexScanBudget?) -> Int64? {
        guard let budget else { return 0 }
        guard !budget.shouldStopBeforeNextFile() else { return nil }
        let workBytes = self.decodedSize(of: archive)
        switch budget.admit(workBytes: workBytes) {
        case .deferBudget:
            return nil
        case let .allow(allowed):
            if allowed < workBytes, budget.bytesConsumed > 0 {
                budget.release(workBytes: allowed)
                return nil
            }
            return allowed
        }
    }

    /// The frame's declared content size, or a conservative estimate when the header omits it.
    private static func decodedSize(of archive: Archive) -> Int64 {
        let estimate = max(1, archive.size) * 8
        guard let handle = try? FileHandle(forReadingFrom: archive.url) else { return estimate }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 18), !header.isEmpty else { return estimate }
        let size = header.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        // ZSTD_CONTENTSIZE_UNKNOWN and ZSTD_CONTENTSIZE_ERROR are the two largest values.
        guard size < UInt64.max - 1, size <= UInt64(Int64.max) else { return estimate }
        return max(1, Int64(size))
    }

    // MARK: - Files

    private static func archives(under sourceRoot: URL, mirrorRoot: URL) -> [Archive] {
        let rootPath = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [Archive] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix(self.rolloutPrefix), name.hasSuffix(self.archiveSuffix) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath),
                  !FileManager.default.fileExists(atPath: String(path.dropLast(".zst".count)))
            else { continue }
            let relativePath = String(path.dropFirst(rootPath.count))
            let mirrorURL = mirrorRoot.appendingPathComponent(
                String(relativePath.dropLast(".zst".count)),
                isDirectory: false)
            out.append(Archive(
                url: url,
                relativePath: relativePath,
                mirrorURL: mirrorURL,
                modified: modified,
                size: Int64(values?.fileSize ?? 0),
                sessionId: self.sessionId(fromArchiveName: name),
                mirrorModified: self.modificationDate(of: mirrorURL)))
        }
        return out
    }

    /// `rollout-<timestamp>-<uuid>.jsonl.zst` -> lowercased `<uuid>`.
    static func sessionId(fromArchiveName name: String) -> String? {
        guard name.hasSuffix(self.archiveSuffix) else { return nil }
        let stem = name.dropLast(self.archiveSuffix.count)
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate.lowercased()
    }

    private static func materialize(archive: Archive, checkCancellation: CostUsageScanner.CancellationCheck?) throws {
        let fileManager = FileManager.default
        let mirrorURL = archive.mirrorURL
        try fileManager.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let partialURL = mirrorURL.deletingLastPathComponent().appendingPathComponent(
            ".\(mirrorURL.lastPathComponent).\(UUID().uuidString)\(self.partialSuffix)",
            isDirectory: false)
        defer { try? fileManager.removeItem(at: partialURL) }
        try self.decompressFile(at: archive.url, to: partialURL, checkCancellation: checkCancellation)
        try fileManager.setAttributes([.modificationDate: archive.modified], ofItemAtPath: partialURL.path)
        if fileManager.fileExists(atPath: mirrorURL.path) {
            _ = try fileManager.replaceItemAt(mirrorURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: mirrorURL)
        }
    }

    private static func pruneMirror(_ mirrorRoot: URL, keeping expected: Set<String>) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: mirrorRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [])
        else { return 0 }
        var removed = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isMirror = name.hasPrefix(self.rolloutPrefix) && name.hasSuffix(".jsonl")
            let isStalePartial = name.hasSuffix(self.partialSuffix)
            guard isMirror || isStalePartial,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if isMirror, expected.contains(url.standardizedFileURL.path) { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil, isMirror {
                removed += 1
            }
        }
        return removed
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Failure ledger

    /// A failed archive, keyed by its relative path. A changed size or mtime makes it eligible again.
    struct FailedArchive: Codable, Equatable {
        let size: Int64
        let modifiedUnixMs: Int64
        let attemptedAt: Date

        init(archive: Archive, attemptedAt: Date) {
            self.size = archive.size
            self.modifiedUnixMs = Int64(archive.modified.timeIntervalSince1970 * 1000)
            self.attemptedAt = attemptedAt
        }

        func matches(_ archive: Archive) -> Bool {
            self.size == archive.size && self.modifiedUnixMs == Int64(archive.modified.timeIntervalSince1970 * 1000)
        }
    }

    private static func loadFailureLedger(mirrorRoot: URL) -> [String: FailedArchive] {
        let url = mirrorRoot.appendingPathComponent(self.failureLedgerName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: FailedArchive].self, from: data)) ?? [:]
    }

    private static func saveFailureLedger(_ ledger: [String: FailedArchive], mirrorRoot: URL) {
        let url = mirrorRoot.appendingPathComponent(self.failureLedgerName, isDirectory: false)
        if ledger.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - zstd

    /// Streams one zstd archive into `destination`, following zstd's streaming_decompression example.
    /// Cancellation is checked once per input chunk, so a large archive cannot hold up a cancelled refresh.
    static func decompressFile(
        at source: URL,
        to destination: URL,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws
    {
        guard let context = ZSTD_createDCtx() else { throw DecodeError.decoderUnavailable }
        defer { ZSTD_freeDCtx(context) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var outBuffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var lastResult = 0
        var sawInput = false
        while let chunk = try input.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
            try checkCancellation?()
            sawInput = true
            try chunk.withUnsafeBytes { rawInput in
                var inBuffer = ZSTD_inBuffer(src: rawInput.baseAddress, size: rawInput.count, pos: 0)
                while inBuffer.pos < inBuffer.size {
                    let written = try outBuffer.withUnsafeMutableBytes { rawOutput -> Data in
                        var zstdOutput = ZSTD_outBuffer(dst: rawOutput.baseAddress, size: rawOutput.count, pos: 0)
                        let code = ZSTD_decompressStream(context, &zstdOutput, &inBuffer)
                        if ZSTD_isError(code) != 0 {
                            throw DecodeError.zstd(String(cString: ZSTD_getErrorName(code)))
                        }
                        lastResult = code
                        return Data(rawOutput.prefix(zstdOutput.pos))
                    }
                    if !written.isEmpty {
                        try output.write(contentsOf: written)
                    }
                }
            }
        }
        // zstd keeps the frame's last input byte until all output is flushed, so a nonzero hint means truncation.
        guard sawInput, lastResult == 0 else { throw DecodeError.truncated }
    }
}
