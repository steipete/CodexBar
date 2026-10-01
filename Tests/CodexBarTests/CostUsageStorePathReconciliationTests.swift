import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageStorePathReconciliationTests {
    @Test
    func `same device identities skip all cached path normalization`() {
        let roots = [
            CostUsageStore.CurrentCodexRootDevice(path: "/synthetic/sessions", device: "17"),
            CostUsageStore.CurrentCodexRootDevice(path: "/synthetic/archived_sessions", device: "17"),
        ]
        var visits = 0
        for index in 0..<25000 {
            let file = Self.file(path: "/synthetic/sessions/missing-\(index).jsonl", identity: "17:\(index)")
            let identity = CostUsageStore.normalizedCodexFileIdentity(file: file, currentRootDevices: roots) { path in
                visits += 1
                return CostUsageStore.normalizedCodexPath(path)
            }
            #expect(identity == file.scanState.fileIdentity)
        }
        #expect(visits == 0)
    }

    @Test
    func `identity shortcut preserves mixed roots and unusual persisted identities`() {
        let rootSets: [[CostUsageStore.CurrentCodexRootDevice]] = [
            [],
            [.init(path: "/synthetic", device: "17")],
            [.init(path: "/synthetic/nested", device: "18"), .init(path: "/synthetic", device: "17")],
        ]
        let identities: [String?] = [nil, "17:42", "18:42", "17:0042", "17:extra:42", "42", "invalid"]
        for roots in rootSets {
            for identity in identities {
                for path in ["/synthetic/missing.jsonl", "/synthetic/nested/missing.jsonl", "/outside/missing.jsonl"] {
                    for persistedInode: Int64? in [nil, 42, 99] {
                        var file = Self.file(path: path, identity: identity)
                        file.inode = persistedInode
                        let expected = Self.legacyIdentity(file: file, roots: roots)
                        #expect(CostUsageStore.normalizedCodexFileIdentity(
                            file: file, currentRootDevices: roots) == expected)
                    }
                }
            }
        }
    }

    @Test
    func `file URL hints preserve paths normalization comparisons and dictionary keys`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let file = env.root.appendingPathComponent("rollout space # café.jsonl", isDirectory: false)
        try Data("synthetic\n".utf8).write(to: file)
        let link = env.root.appendingPathComponent("linked.jsonl", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let missing = env.root.appendingPathComponent("missing.jsonl", isDirectory: false)
        let paths = [
            file.path,
            link.path,
            missing.path,
            env.root.path + "/./" + file.lastPathComponent,
            env.root.path + "/absent/../missing.jsonl",
        ]
        for path in paths {
            let old = URL(fileURLWithPath: path)
            let hinted = URL(fileURLWithPath: path, isDirectory: false)
            #expect(hinted == old)
            #expect(hinted.path == old.path)
            #expect(hinted.standardizedFileURL == old.standardizedFileURL)
            #expect(hinted.standardizedFileURL.path == old.standardizedFileURL.path)
            #expect(hinted.resolvingSymlinksInPath() == old.resolvingSymlinksInPath())
            #expect([old: 7][hinted] == 7)
            #expect([old.standardizedFileURL.path: 7][hinted.standardizedFileURL.path] == 7)
        }
        // Root normalization uses only the path; the URL's directory marker is immaterial.
        for path in paths + [env.root.path, env.root.path + "/", "/var/tmp", "/private/var/tmp"] {
            #expect(CostUsageStore.normalizedCodexPath(path) == Self.legacyPath(path))
        }
    }

    static func file(path: String, identity: String?) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            mtimeUnixMs: 0,
            size: 0,
            scanState: .init(isComplete: true, fileIdentity: identity),
            updatedAtUnixMs: 0)
    }

    private static func legacyPath(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func legacyIdentity(
        file: CostUsageStoreFile,
        roots: [CostUsageStore.CurrentCodexRootDevice]) -> String?
    {
        guard let identity = file.scanState.fileIdentity,
              let inode = identity.split(separator: ":").last.flatMap({ Int64($0) })
        else { return file.scanState.fileIdentity }
        if let persistedInode = file.inode, persistedInode != inode { return identity }
        let path = Self.legacyPath(file.path)
        guard let root = roots.first(where: {
            path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }) else { return identity }
        return "\(root.device):\(inode)"
    }
}

extension CostUsageStorePathReconciliationTests {
    @Test
    func `reconciliation preserves cached missing files and repairs changed state`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let root = env.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let device = try #require(CostUsageScanner.codexFileMetadata(fileURL: root).fileId?.split(separator: ":").first)
        var cache = CostUsageCache()
        cache.codexScanCatchUpPending = false
        var files: [CostUsageStoreFile] = []
        for index in 0..<25000 {
            let file = CostUsageStorePathReconciliationTests.file(
                path: root.path + "/missing-\(index).jsonl", identity: "\(device):\(index)")
            files.append(file)
            cache.files[file.path] = CostUsageFileUsage(
                mtimeUnixMs: 0,
                size: 0,
                days: [:],
                codexScanFileId: file.scanState.fileIdentity,
                codexScanComplete: true)
        }
        var metadata = CostUsageStoreMetadata.empty
        metadata.rootMtimes = [root.path: 0]
        let persistence = CostUsageStore.CodexPersistenceState(snapshot: .init(
            metadata: metadata,
            files: files,
            tokenSnapshots: [],
            fileDayAggregates: [],
            dayAggregates: [],
            forkLineage: [],
            bufferedLines: [],
            accumulators: []))
        #expect(CostUsageStore.reconciledCodexCache(cache, persistence: persistence) == cache)
        let path = try #require(files.first?.path)
        var changed = cache
        changed.files[path]?.codexScanFileId = "stale"
        changed.files[path]?.codexScanComplete = nil
        #expect(CostUsageStore.reconciledCodexCache(changed, persistence: persistence) == cache)
    }
}
