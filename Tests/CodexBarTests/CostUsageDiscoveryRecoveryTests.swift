import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageDiscoveryRecoveryTests {
    @Test(arguments: [false, true], [false, true])
    func `removed fork files do not strand discovery in an existing store`(
        removeCachedRows: Bool,
        keepSibling: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let control = try Self.writeSession(env: env, day: day, sessionID: "control")
        let children = try ["first", "second"].map { name in
            try Self.writeSession(env: env, day: day, sessionID: name, parentID: "parent-\(name)")
        }
        let sibling = try keepSibling ? Self.writeSession(
            env: env,
            day: day.addingTimeInterval(1),
            sessionID: "sibling",
            parentID: "late-parent",
            inputTokens: 150) : nil
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let controlDays = try #require(cache.files[control.path]).days
        #expect(!controlDays.isEmpty)
        for child in children {
            let usage = try #require(cache.files[child.path])
            #expect(usage.days.isEmpty)
            #expect(usage.hasBufferedCodexForkRetryLines)
            try FileManager.default.removeItem(at: child)
            if removeCachedRows {
                cache.files.removeValue(forKey: child.path)
            }
        }

        // Replay the persisted state reported after the requesting children disappeared.
        var discovery = try #require(cache.codexSessionDiscovery)
        discovery.isComplete = false
        discovery.pendingSessionIds = ["parent-first", "parent-second"]
        if keepSibling {
            discovery.pendingSessionIds.append("late-parent")
        }
        discovery.missingSessionIds = []
        discovery.filePathBySessionId["parent-first"] = children[0].path
        discovery.filePathBySessionId["parent-second"] = children[1].path
        #expect(discovery.nextFileIndex == discovery.filePaths.count)
        cache.codexSessionDiscovery = discovery
        cache.codexScanCatchUpPending = true
        cache.codexScanInventoryPaths = nil
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        if removeCachedRows {
            let reopened = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            #expect(children.allSatisfy { reopened.files[$0.path] == nil })
        }
        CostUsageScanner.resetCodexDirectoryCursorsForTesting(under: env.root)

        // Reopen the same SQLite store on each bounded refresh, without a forced rescan.
        options.maxCodexScanBytesPerRefresh = 64
        options.maxCodexScanDurationPerRefresh = 60
        for pass in 1...12 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(pass)),
                options: options)
            cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if cache.codexScanCatchUpPending == false {
                break
            }
        }
        let repaired = try #require(cache.codexSessionDiscovery)
        #expect(repaired.pendingSessionIds.isEmpty)
        #expect(repaired.filePathBySessionId["parent-first"] == nil)
        #expect(repaired.filePathBySessionId["parent-second"] == nil)
        #expect(cache.codexScanCatchUpPending == keepSibling)
        if !keepSibling {
            #expect(cache.codexScanInventoryPaths == [control.path])
        }
        #expect(children.allSatisfy { cache.files[$0.path]?.hasBufferedCodexForkRetryLines != true })
        #expect(cache.files[control.path]?.days == controlDays)
        #expect(cache.days == controlDays)

        if let sibling {
            let unresolved = try #require(cache.files[sibling.path])
            #expect(unresolved.days.isEmpty)
            #expect(unresolved.hasBufferedCodexForkRetryLines)
            _ = try Self.writeSession(env: env, day: day, sessionID: "late-parent")
            options.maxCodexScanBytesPerRefresh = 0
            let resolved = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(20),
                options: options)
            let resolvedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let resolvedChild = try #require(resolvedCache.files[sibling.path])
            #expect(!resolvedChild.days.isEmpty)
            #expect(!resolvedChild.hasBufferedCodexForkRetryLines)
            let stable = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(21),
                options: options)
            #expect(stable.summary?.totalTokens == resolved.summary?.totalTokens)
            #expect(stable.summary?.totalCostUSD == resolved.summary?.totalCostUSD)
            #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[sibling.path]?.days == resolvedChild.days)
        }
    }

    @Test(arguments: [false, true])
    func `pending finalization survives one unit budgets and repeated lookups`(repeatLookup: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let present = try Self.writeSession(env: env, day: day, sessionID: "present")
        var discovery = Self.discovery(pending: ["first", "second", "present"])
        discovery.filePathBySessionId = [
            "first": env.root.appendingPathComponent("removed-first.jsonl").path,
            "second": env.root.appendingPathComponent("removed-second.jsonl").path,
            "present": present.path,
        ]
        for pass in 0..<3 {
            let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 1, maxBytesPerRefresh: 1)
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [], roots: [], cachedDiscovery: discovery, scanBudget: budget)
            if repeatLookup {
                switch try index.lookup(sessionId: "first") {
                case .found: Issue.record("A removed parent must not resolve")
                case .missing: #expect(pass == 2)
                case .deferred: #expect(pass < 2)
                }
            } else {
                try index.resumePendingDiscovery()
            }
            discovery = try JSONDecoder().decode(
                CostUsageCodexSessionDiscovery.self,
                from: JSONEncoder().encode(index.persistedState))
            #expect(budget.bytesConsumed == 1)
            #expect(discovery.pendingSessionIds.count == 2 - pass)
            #expect(discovery.isComplete == (pass == 2))
            #expect((discovery.generation != nil) == (pass == 2))
        }
        #expect(discovery.filePathBySessionId == ["present": present.path])
        #expect(discovery.missingSessionIds == ["first", "second"])
    }

    @Test
    func `cancelled finalization preserves only unprocessed requests`() throws {
        let discovery = Self.discovery(pending: ["first", "second", "third"])
        var checks = 0
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [],
            cachedDiscovery: discovery,
            checkCancellation: {
                checks += 1
                if checks == 3 {
                    throw CancellationError()
                }
            })
        #expect(throws: CancellationError.self) { try index.resumePendingDiscovery() }
        #expect(index.persistedState.pendingSessionIds == ["second", "third"])
        #expect(index.persistedState.missingSessionIds == ["first"])
        #expect(!index.persistedState.isComplete)
        #expect(index.persistedState.generation == nil)
        let resumed = CostUsageScanner.CodexSessionFileIndex(
            files: [], roots: [], cachedDiscovery: index.persistedState)
        try resumed.resumePendingDiscovery()
        #expect(resumed.persistedState.isComplete)
        #expect(resumed.persistedState.pendingSessionIds.isEmpty)
    }

    @Test(arguments: [false, true])
    func `found requests do not scan unrelated inventory`(cached: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parent = try Self.writeSession(env: env, day: day, sessionID: "parent")
        let unrelated = try Self.writeSession(env: env, day: day, sessionID: "unrelated")
        var discovery = Self.discovery(pending: ["parent"])
        discovery.filePaths = [parent.path, unrelated.path]
        discovery.missingSessionIds = ["parent"]
        if cached {
            discovery.filePathBySessionId["parent"] = parent.path
        }
        var headParses = 0
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [],
            cachedDiscovery: discovery,
            headParseObserver: { headParses += 1 })
        guard case let .found(found) = try index.lookup(sessionId: "parent") else {
            Issue.record("Expected the existing parent")
            return
        }
        #expect(found == parent)
        try index.resumePendingDiscovery()
        #expect(headParses == (cached ? 0 : 1))
        #expect(index.persistedState.pendingSessionIds.isEmpty)
        #expect(index.persistedState.missingSessionIds.isEmpty)
        #expect(!index.persistedState.isComplete)
    }

    @Test
    func `new inventory supersedes a partially finalized missing result`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let first = CostUsageScanner.CodexSessionFileIndex(
            files: [],
            roots: [],
            cachedDiscovery: Self.discovery(pending: ["parent", "other"]),
            scanBudget: .init(maxFileBytes: 1, maxBytesPerRefresh: 1))
        try first.resumePendingDiscovery()
        #expect(first.persistedState.missingSessionIds == ["parent"])
        #expect(!first.persistedState.isComplete)
        let parent = try Self.writeSession(env: env, day: day, sessionID: "parent")
        let resumed = CostUsageScanner.CodexSessionFileIndex(
            files: [parent], roots: [], cachedDiscovery: first.persistedState)
        try resumed.resumePendingDiscovery()
        #expect(resumed.persistedState.isComplete)
        #expect(resumed.persistedState.missingSessionIds == ["other"])
        #expect(resumed.persistedState.filePathBySessionId["parent"] == parent.path)
    }

    @Test
    func `resolved demand abandons its partial head without advancing inventory`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parent = try Self.writeSession(env: env, day: day, sessionID: "parent")
        var discovery = Self.discovery(pending: ["parent"])
        discovery.filePaths = [parent.path]
        discovery.headScan = .init(path: parent.path, offset: 2, resumeState: nil)
        let index = CostUsageScanner.CodexSessionFileIndex(files: [], roots: [], cachedDiscovery: discovery)
        index.remember(fileURL: parent, sessionId: "parent")
        try index.resumePendingDiscovery()
        #expect(index.persistedState.headScan == nil)
        #expect(index.persistedState.nextFileIndex == 0)
        #expect(!index.persistedState.isComplete)
        #expect(!index.hasPendingDiscovery)
        guard case .missing = try index.lookup(sessionId: "absent") else {
            Issue.record("Future demand must restart the abandoned head")
            return
        }
        #expect(index.persistedState.nextFileIndex == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func `removed and empty heads respect byte and time budgets`(emptyFiles: Bool, timeLimit: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let paths = try (0..<3).map { number in
            let file = env.root.appendingPathComponent("head-\(number).jsonl")
            if emptyFiles {
                try Data().write(to: file)
            }
            return file.path
        }
        var discovery = Self.discovery(pending: ["absent"])
        discovery.filePaths = paths
        for pass in 0..<4 {
            let origin = ContinuousClock.now
            let clock = LockIsolated(origin)
            let budget = CostUsageScanner.CodexScanBudget(
                maxFileBytes: 0,
                maxBytesPerRefresh: timeLimit ? 0 : 1,
                maxDuration: timeLimit ? 1 : nil,
                now: { clock.value })
            clock.setValue(origin.advanced(by: .seconds(2)))
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [], roots: [], cachedDiscovery: discovery, scanBudget: budget)
            try index.resumePendingDiscovery()
            discovery = index.persistedState
            #expect(budget.bytesConsumed == 1)
            #expect(discovery.nextFileIndex == min(pass + 1, 3))
            #expect(discovery.isComplete == (pass == 3))
            #expect(discovery.pendingSessionIds.isEmpty == (pass == 3))
        }
    }

    private static func discovery(pending: [String]) -> CostUsageCodexSessionDiscovery {
        CostUsageCodexSessionDiscovery(
            roots: [],
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
            pendingSessionIds: pending,
            validationDirectoryIndex: 0,
            isComplete: false)
    }

    private static func writeSession(
        env: CostUsageTestEnvironment,
        day: Date,
        sessionID: String,
        parentID: String? = nil,
        inputTokens: Int = 100) throws -> URL
    {
        let iso = env.isoString(for: day)
        let parent = parentID.map { #", "forked_from_id":"\#($0)""# } ?? ""
        return try env.writeCodexSessionFile(
            day: day,
            filename: "\(sessionID).jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"\#(sessionID)"\#(parent)}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":\#(inputTokens),"#
                    + #""cached_input_tokens":10,"output_tokens":5},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")
    }
}
