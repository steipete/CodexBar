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
enum CodexArchivedRolloutMirror {
    static let archiveSuffix = ".jsonl.zst"
    private static let rolloutPrefix = "rollout-"
    private static let partialSuffix = ".partial"
    /// Same-mtime check for an already mirrored archive; Foundation round-trips through `Double` seconds.
    private static let mtimeTolerance: TimeInterval = 0.01

    struct SyncResult: Equatable {
        var materialized = 0
        var removed = 0
        var failed = 0
    }

    enum DecodeError: Error, Equatable {
        case decoderUnavailable
        case zstd(String)
        case truncated
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

    /// Brings each source root's mirror up to date. Archives last modified before `modifiedSince` are only
    /// materialized on demand by a wider window; mirrors that already exist are kept until their archive is
    /// removed or its plain `.jsonl` returns, because dropping them would drop their cached usage too.
    @discardableResult
    static func sync(
        sourceRoots: [URL],
        cacheRoot: URL?,
        modifiedSince: Date?,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> SyncResult
    {
        var result = SyncResult()
        for sourceRoot in sourceRoots {
            try self.sync(
                sourceRoot: sourceRoot.standardizedFileURL,
                mirrorRoot: self.mirrorRoot(for: sourceRoot, cacheRoot: cacheRoot),
                modifiedSince: modifiedSince,
                result: &result,
                checkCancellation: checkCancellation)
        }
        return result
    }

    private static func sync(
        sourceRoot: URL,
        mirrorRoot: URL,
        modifiedSince: Date?,
        result: inout SyncResult,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws
    {
        let fileManager = FileManager.default
        var expected: Set<String> = []
        for archive in self.archives(under: sourceRoot) {
            try checkCancellation?()
            let plainPath = String(archive.url.path.dropLast(".zst".count))
            guard !fileManager.fileExists(atPath: plainPath) else { continue }
            let mirrorURL = mirrorRoot.appendingPathComponent(
                String(archive.relativePath.dropLast(".zst".count)),
                isDirectory: false)
            let mirrorDate = self.modificationDate(of: mirrorURL)
            if let modifiedSince, archive.modified < modifiedSince, mirrorDate == nil { continue }
            expected.insert(mirrorURL.standardizedFileURL.path)
            if let mirrorDate, abs(mirrorDate.timeIntervalSince(archive.modified)) < self.mtimeTolerance {
                continue
            }
            do {
                try self.materialize(archive: archive.url, modified: archive.modified, to: mirrorURL)
                result.materialized += 1
            } catch {
                // Leave any previous mirror in place; a failed decode should not erase cached usage.
                result.failed += 1
            }
        }
        result.removed += self.pruneMirror(mirrorRoot, keeping: expected)
    }

    private struct Archive {
        let url: URL
        let relativePath: String
        let modified: Date
    }

    private static func archives(under sourceRoot: URL) -> [Archive] {
        let rootPath = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [Archive] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix(self.rolloutPrefix), name.hasSuffix(self.archiveSuffix) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            out.append(Archive(url: url, relativePath: String(path.dropFirst(rootPath.count)), modified: modified))
        }
        return out
    }

    private static func materialize(archive: URL, modified: Date, to mirrorURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let partialURL = mirrorURL.deletingLastPathComponent().appendingPathComponent(
            ".\(mirrorURL.lastPathComponent).\(UUID().uuidString)\(self.partialSuffix)",
            isDirectory: false)
        defer { try? fileManager.removeItem(at: partialURL) }
        try self.decompressFile(at: archive, to: partialURL)
        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: partialURL.path)
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

    // MARK: - zstd

    /// Streams one zstd archive into `destination`, following zstd's streaming_decompression example.
    static func decompressFile(at source: URL, to destination: URL) throws {
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
