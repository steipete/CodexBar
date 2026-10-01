import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFileListingTests {
    @Test
    func `listing preserves legacy path keys and lookback aliases across root spellings`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fm = FileManager.default
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)
        let link = env.root.appendingPathComponent("linked-home", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: env.codexHomeRoot)
        for root in [env.codexSessionsRoot, env.codexArchivedSessionsRoot] {
            for relative in [
                "2026/09/29/older.jsonl",
                "2026/09/30/a.jsonl",
                "2026/09/30/b.jsonl",
                "2026/09/30/large.jsonl",
                "2026/09/30/space % café.jsonl",
                "flat.jsonl",
                "legacy/nested.jsonl",
            ] {
                let file = root.appendingPathComponent(relative, isDirectory: false)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 32, count: relative.contains("large") ? 8 : 1).write(to: file)
                try fm.setAttributes(
                    [.modificationDate: relative.contains("older") ? day.addingTimeInterval(-86400) : day],
                    ofItemAtPath: file.path)
            }
            try fm.createSymbolicLink(
                at: root.appendingPathComponent("alias.jsonl", isDirectory: false),
                withDestinationURL: root.appendingPathComponent("2026/09/30/a.jsonl", isDirectory: false))
        }
        let plain = env.codexSessionsRoot.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        var spellings = [plain + "/", link.path + "/sessions/", link.path + "/../linked-home/sessions///"]
        if plain.hasPrefix("/var/") { spellings.append("/private" + plain) }
        for spelling in spellings {
            let options = CostUsageScanner.Options(codexSessionsRoot: URL(fileURLWithPath: spelling, isDirectory: true))
            for root in CostUsageScanner.codexSessionsRoots(options: options) {
                let legacy = try Self.legacyListing(root: root)
                let recorder = CostUsageScanner.CodexScanWorkRecorder()
                let listed = CostUsageScanner.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: "2026-09-29",
                    scanUntilKey: "2026-09-30",
                    includeRecursive: true,
                    workRecorder: recorder)
                let keys = listed.map { CostUsageScanner.codexPathKey(standardizedPath: $0.path) }
                #expect(Self.pathBytes(keys) == Self.pathBytes(legacy.map(CostUsageScanner.codexPathKey)))
                #expect(recorder.snapshot().codexListingRootStandardizations == 1)
                let missing = root.appendingPathComponent("missing.jsonl", isDirectory: false)
                let candidates = listed + [missing, listed[0]]
                let sorted = CostUsageScanner.sortedCodexSessionFilesNewestFirst(candidates)
                #expect(Self.pathBytes(sorted.map(\.path)) == Self.pathBytes(Self.legacySorted(candidates).map(\.path)))
                var state = CostUsageCodexActiveLookbackState(
                    scanSinceKey: "2026-09-29", rootPaths: [], pendingFilePaths: [missing.path])
                CostUsageScanner.appendCodexActiveLookbackPaths(sorted, normalizeExisting: true, state: &state)
                var seen: Set<String> = []
                let expected = ([missing] + sorted).map(Self.resolvedKey).filter { seen.insert($0).inserted }
                #expect(Self.pathBytes(state.pendingFilePaths) == Self.pathBytes(expected))
            }
        }
    }

    @Test
    func `bookkeeping reads metadata once per file across catch-up sorts and refreshes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)
        let count = 12
        for index in 0..<count {
            _ = try env.seedCodexSessionFile(day: day, filename: "listing-\(index).jsonl", contents: "{}\n")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite", isDirectory: false),
            maxCodexSessionFileBytes: 1,
            maxCodexScanBytesPerRefresh: 1)
        options.refreshMinIntervalSeconds = 0
        for run in 0..<2 {
            let recorder = CostUsageScanner.CodexScanWorkRecorder()
            options.codexScanWorkRecorderForTesting = recorder
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(run)),
                options: options,
                checkCancellation: nil)
            #expect(recorder.snapshot().codexListingMetadataReads == count)
            #expect(recorder.snapshot().codexListingRootStandardizations == 2)
        }
    }

    private static func pathBytes(_ paths: [String]) -> [[UInt8]] {
        paths.map { Array($0.utf8) }
    }

    private static func legacyListing(root: URL) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for day in ["29", "30"] {
            files += try fm.contentsOfDirectory(
                at: root.appendingPathComponent("2026/09/\(day)", isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "jsonl" }
        }
        files += try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]).filter { $0.pathExtension.lowercased() == "jsonl" }
        let enumerator = try #require(fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]))
        while let item = enumerator.nextObject() as? URL {
            let relative = item.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            if relative == "2026" { enumerator.skipDescendants(); continue }
            if item.pathExtension.lowercased() == "jsonl" { files.append(item) }
        }
        var seen: Set<String> = []
        return files.filter { seen.insert(CostUsageScanner.codexPathKey($0)).inserted }
    }

    private static func legacySorted(_ files: [URL]) -> [URL] {
        let metadata = files.reduce(into: [String: CostUsageScanner.CodexFileMetadata]()) {
            $0[$1.path] = CostUsageScanner.codexFileMetadata(fileURL: $1)
        }
        return files.sorted {
            let left = metadata[$0.path]!
            let right = metadata[$1.path]!
            if left.mtimeUnixMs != right.mtimeUnixMs { return left.mtimeUnixMs > right.mtimeUnixMs }
            if left.size != right.size { return left.size < right.size }
            return $0.path < $1.path
        }
    }

    private static func resolvedKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
            .replacingOccurrences(of: "/private/var/", with: "/var/", options: [.anchored])
    }
}
