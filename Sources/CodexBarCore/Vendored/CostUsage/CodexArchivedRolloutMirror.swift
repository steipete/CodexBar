#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CZstd
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Codex archives finished rollouts as `rollout-*.jsonl.zst` and later deletes the plain `.jsonl`.
/// The cost scanner resumes plain JSONL by byte offset, so archived rollouts are decoded into a
/// CodexBar-owned mirror instead: same relative layout as the source root, archive mtime preserved.
/// The mirror only holds rollouts whose plain `.jsonl` sibling is gone, so a rollout is never counted twice.
///
/// A refresh first lists archives (`prepare`), then decodes them under its `CodexScanBudget` (`materialize`).
/// Like a large plain rollout, an archive that exceeds the refresh's byte or time budget is decoded in
/// resumable slices: output goes to a hidden `.resume` file, locked while it is written, and the decoder
/// is kept in memory so the next refresh continues where this one paused.
enum CodexArchivedRolloutMirror {
    static let archiveSuffix = ".jsonl.zst"
    /// A corrupt or unwritable archive is retried when it changes, or after this interval.
    static let failedArchiveRetryInterval: TimeInterval = 60 * 60
    /// Request once the header's size estimate is used up: far above any refresh budget, yet small enough
    /// that `CodexScanBudget`'s byte sums cannot overflow when no byte cap applies.
    private static let unknownRemainderRequest: Int64 = 1 << 40
    private static let rolloutPrefix = "rollout-"
    private static let resumeSuffix = ".resume"
    private static let failureLedgerName = ".failed-archives.json"
    /// Same-mtime check for an already mirrored archive; Foundation round-trips through `Double` seconds.
    private static let mtimeTolerance: TimeInterval = 0.01
    /// Directory walks check cancellation every this many entries.
    private static let walkCancellationInterval = 256
    /// Mirrors hold whole decoded transcripts, which may be private at their source, so every file and
    /// directory under the mirror container is owner-only regardless of the umask.
    private static let privateFileMode: mode_t = 0o600
    private static let privateDirectoryMode: mode_t = 0o700

    struct SyncResult: Equatable {
        var materialized = 0
        var removed = 0
        /// Archives that failed to decode or write, including ones waiting out their retry interval.
        var failed = 0
        /// Archives left for a later refresh by the scan budget, or because another process holds them.
        var deferred = 0
        var materializedSessionIds: Set<String> = []
        /// Mirror paths of failed or deferred archives, so callers do not count them twice.
        var pendingMirrorPaths: Set<String> = []

        var hasPendingWork: Bool {
            self.failed > 0 || self.deferred > 0
        }
    }

    enum DecodeError: Error, Equatable {
        case decoderUnavailable
        case zstd(String)
        case truncated
        case sliceUnavailable
    }

    /// Cancellation observed mid-archive. The slice and decoder are kept; callers rethrow `underlying`.
    struct DecodeCancelled: Error {
        let underlying: any Error
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

        /// Hidden slice output, named for the archive's size and mtime so a changed archive restarts.
        var resumeURL: URL {
            let modifiedMs = Int64(self.modified.timeIntervalSince1970 * 1000)
            let name = ".\(self.mirrorURL.lastPathComponent).\(self.size)-\(modifiedMs)"
            return self.mirrorURL.deletingLastPathComponent().appendingPathComponent(
                name + CodexArchivedRolloutMirror.resumeSuffix,
                isDirectory: false)
        }

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

        var isEmpty: Bool {
            self.roots.allSatisfy(\.archives.isEmpty)
        }

        /// Archives holding one of `sessionIds` that are not mirrored yet and not already counted as pending.
        func unmirroredArchiveCount(
            forSessionIds sessionIds: Set<String>,
            excluding result: SyncResult) -> Int
        {
            let wanted = sessionIds.subtracting(result.materializedSessionIds)
            guard !wanted.isEmpty else { return 0 }
            return self.roots.reduce(0) { count, root in
                count + root.archives.count { archive in
                    archive.sessionId.map(wanted.contains) == true && !archive.mirrorIsCurrent
                        && !result.pendingMirrorPaths.contains(archive.mirrorURL.standardizedFileURL.path)
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

    /// Creates the mirror root and its container owner-only, and tightens them if an earlier build or
    /// another tool left them readable by other users. Everything else under the root is created private.
    private static func createPrivateMirrorRoot(_ mirrorRoot: URL) throws {
        let container = mirrorRoot.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: container.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: mirrorRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(self.privateDirectoryMode)])
        for directory in [container, mirrorRoot] {
            guard chmod(directory.path, self.privateDirectoryMode) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }

    // MARK: - Phases

    /// Source roots recently found to hold no archives, so the probe below does not rewalk them every refresh.
    private final class EmptyRootProbes: @unchecked Sendable {
        private let lock = NSLock()
        private var checkedAt: [String: ContinuousClock.Instant] = [:]
        private let interval: Duration = .seconds(10 * 60)

        func isFresh(_ path: String) -> Bool {
            self.lock.withLock { self.checkedAt[path].map { $0.duration(to: .now) < self.interval } ?? false }
        }

        func record(_ path: String, empty: Bool) {
            self.lock.withLock { self.checkedAt[path] = empty ? .now : nil }
        }
    }

    private static let emptyRootProbes = EmptyRootProbes()

    /// Creates the mirror root for any source root that holds an archive, before roots are fingerprinted, so
    /// the refresh that first decodes archives also scans them. An existing mirror root costs one stat; a
    /// source root without one is probed until its first archive, and an empty result is remembered briefly.
    static func ensureMirrorRoots(
        sourceRoots: [URL],
        cacheRoot: URL?,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws
    {
        for sourceRoot in sourceRoots {
            let mirrorRoot = self.mirrorRoot(for: sourceRoot, cacheRoot: cacheRoot)
            let key = sourceRoot.standardizedFileURL.path
            guard !FileManager.default.fileExists(atPath: mirrorRoot.path), !self.emptyRootProbes.isFresh(key)
            else { continue }
            let hasArchive = try self.containsArchive(
                under: sourceRoot.standardizedFileURL,
                checkCancellation: checkCancellation)
            self.emptyRootProbes.record(key, empty: !hasArchive)
            if hasArchive {
                try? self.createPrivateMirrorRoot(mirrorRoot)
            }
        }
    }

    private static func containsArchive(
        under sourceRoot: URL,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Bool
    {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        for (index, element) in enumerator.enumerated() {
            if index % self.walkCancellationInterval == 0 { try checkCancellation?() }
            guard let url = element as? URL else { continue }
            let name = url.lastPathComponent
            guard name.hasPrefix(self.rolloutPrefix), name.hasSuffix(self.archiveSuffix) else { continue }
            if !FileManager.default.fileExists(atPath: String(url.path.dropLast(".zst".count))) {
                return true
            }
        }
        return false
    }

    /// Lists archives, prunes mirrors and slices whose archive is gone, changed, or whose plain `.jsonl`
    /// returned, and creates mirror roots that are needed. Decodes nothing.
    static func prepare(
        sourceRoots: [URL],
        cacheRoot: URL?,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Inventory
    {
        var inventory = Inventory()
        for sourceRoot in sourceRoots {
            try checkCancellation?()
            let mirrorRoot = self.mirrorRoot(for: sourceRoot, cacheRoot: cacheRoot)
            let archives = try self.archives(
                under: sourceRoot.standardizedFileURL,
                mirrorRoot: mirrorRoot,
                checkCancellation: checkCancellation)
            inventory.removed += self.pruneMirror(
                mirrorRoot,
                keeping: Set(archives.flatMap {
                    [$0.mirrorURL.standardizedFileURL.path, $0.resumeURL.standardizedFileURL.path]
                }))
            if !archives.isEmpty {
                try self.createPrivateMirrorRoot(mirrorRoot)
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
        var admittedArchive = false
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
            func deferRemaining(from index: Int) {
                result.deferred += work.count - index
                result.pendingMirrorPaths.formUnion(work[index...].map(\.mirrorURL.standardizedFileURL.path))
            }
            for (index, archive) in work.enumerated() {
                try checkCancellation?()
                if let failure = ledger[archive.relativePath], failure.matches(archive),
                   now.timeIntervalSince(failure.attemptedAt) < self.failedArchiveRetryInterval
                {
                    result.failed += 1
                    result.pendingMirrorPaths.insert(archive.mirrorURL.standardizedFileURL.path)
                    continue
                }
                // Ask for the estimated remainder. Once the estimate is used up (no content size in the header,
                // or a later frame it did not count), ask for whatever the refresh has left, so slices never shrink.
                let estimatedRemaining = self.decodedSize(of: archive) - self.fileSize(of: archive.resumeURL)
                guard let allowance = self.admit(
                    workBytes: estimatedRemaining > 0 ? estimatedRemaining : self.unknownRemainderRequest,
                    budget: budget,
                    isFirstAdmission: !admittedArchive)
                else {
                    deferRemaining(from: index)
                    break
                }
                admittedArchive = true
                do {
                    let outcome = try self.decode(
                        archive,
                        maxNewBytes: allowance,
                        shouldPause: { budget?.shouldYield(additionalBytes: 0) ?? false },
                        checkCancellation: checkCancellation)
                    budget?.complete(admittedWorkBytes: allowance, actualWorkBytes: outcome.written)
                    if outcome.isBusy {
                        // Another process is writing this slice; it publishes the mirror itself.
                        result.deferred += 1
                        result.pendingMirrorPaths.insert(archive.mirrorURL.standardizedFileURL.path)
                        continue
                    }
                    guard outcome.isComplete else {
                        // The byte or time budget ran out mid-archive; this and the rest resume next refresh.
                        deferRemaining(from: index)
                        break
                    }
                    ledger[archive.relativePath] = nil
                    result.materialized += 1
                    if let sessionId = archive.sessionId {
                        result.materializedSessionIds.insert(sessionId)
                    }
                } catch let cancelled as DecodeCancelled {
                    budget?.release(workBytes: allowance)
                    throw cancelled.underlying
                } catch DecodeError.sliceUnavailable {
                    // The cache volume refused the slice (for example EIO or EMFILE); retry next refresh.
                    budget?.release(workBytes: allowance)
                    result.deferred += 1
                    result.pendingMirrorPaths.insert(archive.mirrorURL.standardizedFileURL.path)
                } catch {
                    budget?.release(workBytes: allowance)
                    ledger[archive.relativePath] = FailedArchive(archive: archive, attemptedAt: now)
                    result.failed += 1
                    result.pendingMirrorPaths.insert(archive.mirrorURL.standardizedFileURL.path)
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

    /// Returns how many new decoded bytes this refresh may write for an archive, or nil to defer it.
    /// A partial allowance is a resumable slice, exactly like a large plain rollout's. The first archive of a
    /// refresh is not held to the deadline: listing a large history can use it all up, and deferring every
    /// archive would repeat that listing each refresh without ever decoding. `decode` still pauses after a step.
    private static func admit(
        workBytes: Int64,
        budget: CostUsageScanner.CodexScanBudget?,
        isFirstAdmission: Bool) -> Int64?
    {
        guard let budget else { return .max }
        guard isFirstAdmission || !budget.shouldStopBeforeNextFile() else { return nil }
        switch budget.admit(workBytes: workBytes) {
        case .deferBudget:
            return nil
        case let .allow(allowed):
            guard allowed > 0 else {
                budget.release(workBytes: allowed)
                return nil
            }
            return allowed
        }
    }

    /// The first frame's declared content size, or a rough estimate when the header omits it.
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

    private static func archives(
        under sourceRoot: URL,
        mirrorRoot: URL,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> [Archive]
    {
        let rootPath = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [Archive] = []
        for (index, element) in enumerator.enumerated() {
            if index % self.walkCancellationInterval == 0 { try checkCancellation?() }
            guard let url = element as? URL else { continue }
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

    private static func fileSize(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
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
            let isSlice = name.hasSuffix(self.resumeSuffix)
            guard isMirror || isSlice,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            if expected.contains(path) {
                self.restrictToOwner(url)
                continue
            }
            if isSlice {
                self.sessions.discard(path)
            }
            if (try? FileManager.default.removeItem(at: url)) != nil, isMirror {
                removed += 1
            }
        }
        return removed
    }

    /// Tightens a mirror or slice an earlier build created with the umask's mode.
    private static func restrictToOwner(_ url: URL) {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & 0o077 != 0 else { return }
        _ = chmod(url.path, self.privateFileMode)
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
        guard let data = try? JSONEncoder().encode(ledger), (try? self.createPrivateMirrorRoot(mirrorRoot)) != nil
        else { return }
        _ = FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: Int(self.privateFileMode)])
    }

    // MARK: - zstd

    struct DecodeOutcome: Equatable {
        /// The archive is fully decoded and its mirror is published.
        let isComplete: Bool
        /// New decoded bytes written to the slice in this call.
        let written: Int64
        /// Another process holds the slice lock; nothing was decoded.
        var isBusy = false
    }

    /// Decoder state for an archive paused mid-slice. Kept per process, keyed by slice path; a relaunch
    /// starts a fresh decoder that skips the bytes already on disk.
    private final class DecodeSession {
        let context: OpaquePointer
        let input: FileHandle
        var pendingInput = Data()
        var pendingInputOffset = 0
        /// Decoded bytes not yet written to the slice.
        var pendingOutput = Data()
        /// Decoded bytes already accounted to the slice (written or skipped).
        var consumedOutput: Int64 = 0
        var lastResult = 0
        var sawInput = false
        var inputFinished = false
        private var outputBuffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())

        init(archive: URL) throws {
            guard let context = ZSTD_createDCtx() else { throw DecodeError.decoderUnavailable }
            do {
                self.input = try FileHandle(forReadingFrom: archive)
            } catch {
                ZSTD_freeDCtx(context)
                throw error
            }
            self.context = context
        }

        deinit {
            ZSTD_freeDCtx(self.context)
            try? self.input.close()
        }

        /// Runs one `ZSTD_decompressStream` step on buffered input, appending its output.
        func step() throws {
            var nextOffset = self.pendingInputOffset
            var producedCount = 0
            var code = 0
            let context = self.context
            try self.pendingInput.withUnsafeBytes { rawInput in
                var inBuffer = ZSTD_inBuffer(src: rawInput.baseAddress, size: rawInput.count, pos: nextOffset)
                try self.outputBuffer.withUnsafeMutableBytes { rawOutput in
                    var zstdOutput = ZSTD_outBuffer(dst: rawOutput.baseAddress, size: rawOutput.count, pos: 0)
                    code = ZSTD_decompressStream(context, &zstdOutput, &inBuffer)
                    if ZSTD_isError(code) != 0 {
                        throw DecodeError.zstd(String(cString: ZSTD_getErrorName(code)))
                    }
                    producedCount = zstdOutput.pos
                }
                nextOffset = inBuffer.pos
            }
            self.lastResult = code
            self.pendingInputOffset = nextOffset
            self.pendingOutput.append(contentsOf: self.outputBuffer[0..<producedCount])
        }
    }

    /// Paused decoders, newest last. At most `capacity` are kept, and one idle past `idleLimit` is dropped,
    /// so an archive that is never revisited does not pin its decoder window and file handle.
    private final class DecodeSessionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [(path: String, session: DecodeSession, parkedAt: ContinuousClock.Instant)] = []
        private let capacity = 2
        private let idleLimit: Duration = .seconds(10 * 60)

        func take(_ path: String) -> DecodeSession? {
            self.lock.withLock {
                self.dropIdle()
                guard let index = self.sessions.firstIndex(where: { $0.path == path }) else { return nil }
                return self.sessions.remove(at: index).session
            }
        }

        func park(_ path: String, _ session: DecodeSession) {
            self.lock.withLock {
                self.dropIdle()
                self.sessions.removeAll { $0.path == path }
                self.sessions.append((path, session, ContinuousClock.now))
                if self.sessions.count > self.capacity {
                    self.sessions.removeFirst(self.sessions.count - self.capacity)
                }
            }
        }

        func discard(_ path: String) {
            self.lock.withLock { self.sessions.removeAll { $0.path == path } }
        }

        func removeAll() {
            self.lock.withLock { self.sessions.removeAll() }
        }

        var count: Int {
            self.lock.withLock { self.sessions.count }
        }

        private func dropIdle() {
            let now = ContinuousClock.now
            self.sessions.removeAll { $0.parkedAt.duration(to: now) > self.idleLimit }
        }
    }

    private static let sessions = DecodeSessionStore()

    /// Simulates a relaunch: paused slices must resume from disk without their in-memory decoder.
    static func discardDecodeSessionsForTesting() {
        self.sessions.removeAll()
    }

    static var parkedDecodeSessionCountForTesting: Int {
        self.sessions.count
    }

    /// Decodes up to `maxNewBytes` more bytes of `archive` into its slice and publishes the mirror once the
    /// archive is complete, all under an exclusive lock on the slice so concurrent processes cannot interleave.
    /// Stops early when `shouldPause` reports the refresh deadline (checked before every decode step) and
    /// checks cancellation before each input chunk. A paused or cancelled decode keeps its slice and decoder;
    /// a corrupt archive or write failure discards both, and a slice longer than the archive restarts.
    static func decode(
        _ archive: Archive,
        maxNewBytes: Int64,
        shouldPause: () -> Bool = { false },
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> DecodeOutcome
    {
        let fileManager = FileManager.default
        let sliceURL = archive.resumeURL
        let key = sliceURL.standardizedFileURL.path
        guard let descriptor = try self.openLockedSlice(sliceURL) else {
            return DecodeOutcome(isComplete: false, written: 0, isBusy: true)
        }
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        if self.modificationDate(of: archive.mirrorURL)
            .map({ abs($0.timeIntervalSince(archive.modified)) < self.mtimeTolerance }) == true
        {
            // Another process published this archive after our inventory was taken.
            self.sessions.discard(key)
            try? fileManager.removeItem(at: sliceURL)
            return DecodeOutcome(isComplete: true, written: 0)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw DecodeError.sliceUnavailable }
        let onDisk = Int64(status.st_size)

        var parked = false
        var reused = self.sessions.take(key)
        // A session behind the slice (paused while replaying its prefix) skips the rest; one ahead of it
        // means the slice was shortened, so it starts over.
        if let session = reused, session.consumedOutput > onDisk {
            reused = nil
        }
        do {
            var session = try reused ?? DecodeSession(archive: archive.url)
            func park() {
                parked = true
                self.sessions.park(key, session)
            }
            var skip = max(0, onDisk - session.consumedOutput)
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try output.seekToEnd()
            var written: Int64 = 0
            var stepped = false
            while true {
                if !session.pendingOutput.isEmpty, skip > 0 {
                    let count = Int(min(skip, Int64(session.pendingOutput.count)))
                    session.pendingOutput.removeFirst(count)
                    session.consumedOutput += Int64(count)
                    skip -= Int64(count)
                }
                if !session.pendingOutput.isEmpty {
                    let room = maxNewBytes - written
                    guard room > 0 else {
                        park()
                        return DecodeOutcome(isComplete: false, written: written)
                    }
                    let count = Int(min(room, Int64(session.pendingOutput.count)))
                    try output.write(contentsOf: session.pendingOutput.prefix(count))
                    session.pendingOutput.removeFirst(count)
                    session.consumedOutput += Int64(count)
                    written += Int64(count)
                    continue
                }
                if session.inputFinished {
                    // zstd keeps a frame's last input byte until its output is flushed; a nonzero hint is truncation.
                    guard session.sawInput, session.lastResult == 0 else { throw DecodeError.truncated }
                    guard skip == 0 else {
                        // The slice is longer than the archive decodes to; truncate it and decode again now.
                        guard ftruncate(descriptor, 0) == 0 else { throw DecodeError.sliceUnavailable }
                        try output.seek(toOffset: 0)
                        session = try DecodeSession(archive: archive.url)
                        skip = 0
                        written = 0
                        continue
                    }
                    try self.publish(archive, sliceURL: sliceURL)
                    return DecodeOutcome(isComplete: true, written: written)
                }
                // An admitted archive makes at least one step of progress even past the deadline, so a slow
                // inventory or a long replay cannot starve it forever.
                if stepped || written > 0, shouldPause() {
                    park()
                    return DecodeOutcome(isComplete: false, written: written)
                }
                if session.pendingInputOffset >= session.pendingInput.count {
                    do {
                        try checkCancellation?()
                    } catch {
                        park()
                        throw DecodeCancelled(underlying: error)
                    }
                    guard let chunk = try session.input.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty else {
                        session.inputFinished = true
                        continue
                    }
                    session.sawInput = true
                    session.pendingInput = chunk
                    session.pendingInputOffset = 0
                }
                try session.step()
                stepped = true
            }
        } catch {
            if !parked {
                self.sessions.discard(key)
                try? fileManager.removeItem(at: sliceURL)
            }
            throw error
        }
    }

    /// Opens the slice owner-only and takes its exclusive lock; nil when another process holds it.
    private static func openLockedSlice(_ sliceURL: URL) throws -> Int32? {
        try FileManager.default.createDirectory(
            at: sliceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(self.privateDirectoryMode)])
        let descriptor = sliceURL.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, self.privateFileMode)
        }
        guard descriptor >= 0 else { throw DecodeError.sliceUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            _ = close(descriptor)
            if busy { return nil }
            throw DecodeError.sliceUnavailable
        }
        // `open` applies the mode only on creation; a slice resumed from an earlier build is tightened here.
        // Publishing renames this same file, so the mirror keeps the mode.
        guard fchmod(descriptor, self.privateFileMode) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw DecodeError.sliceUnavailable
        }
        return descriptor
    }

    /// Moves a finished slice into place with the archive's mtime, while its lock is still held.
    private static func publish(_ archive: Archive, sliceURL: URL) throws {
        let fileManager = FileManager.default
        // Another process pruned the slice (its archive changed); retry next refresh instead of failing.
        guard fileManager.fileExists(atPath: sliceURL.path) else { throw DecodeError.sliceUnavailable }
        try fileManager.setAttributes([.modificationDate: archive.modified], ofItemAtPath: sliceURL.path)
        if fileManager.fileExists(atPath: archive.mirrorURL.path) {
            // The default keeps the old mirror's permissions; the slice's owner-only mode must win.
            _ = try fileManager.replaceItemAt(archive.mirrorURL, withItemAt: sliceURL, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: sliceURL, to: archive.mirrorURL)
        }
    }

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
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: Int(self.privateFileMode)])
        else {
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
