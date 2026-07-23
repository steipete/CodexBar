import Foundation
import Testing
@testable import CodexBarCore

struct CodexCompactSubagentAccountingTests {
    private typealias Fixture = CodexCompactSubagentFixture
    private typealias Usage = Fixture.Usage

    @Test
    func `parent-confirmed first turn marker drops a compact copied prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 17)
        let parentModel = "openai/gpt-5.3"
        let leafModel = "openai/gpt-5.4"
        let prefix: Usage = (input: 1000, cached: 900, output: 100)
        let suffix: Usage = (input: 50, cached: 10, output: 5)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-parent.jsonl",
            contents: Fixture.parentContents(
                env: env,
                day: day,
                sessionID: "compact-parent",
                model: parentModel,
                totals: prefix))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-child.jsonl",
            contents: Fixture.childContents(
                env: env,
                day: day,
                fixture: Fixture.Child(
                    sessionID: "compact-child",
                    parentID: "compact-parent",
                    leafModel: leafModel,
                    prefix: prefix,
                    suffix: suffix,
                    preBoundaryLast: (input: 7, cached: 3, output: 2))))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        options.forceRescan = true
        let forced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)

        for report in [cold, warm, forced] {
            let daily = try #require(report.data.first)
            #expect(daily.totalTokens == 1155)
            let breakdowns = try #require(daily.modelBreakdowns)
            #expect(!breakdowns.contains { $0.modelName == CostUsagePricing.codexUnattributedModel })
            #expect(breakdowns.first {
                $0.modelName == CostUsagePricing.normalizeCodexModel(parentModel)
            }?.totalTokens == 1100)
            #expect(breakdowns.first {
                $0.modelName == CostUsagePricing.normalizeCodexModel(leafModel)
            }?.totalTokens == 55)
        }

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let child = try #require(cache.files.values.first { $0.sessionId == "compact-child" })
        #expect(child.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)]?[
            CostUsagePricing.normalizeCodexModel(leafModel),
        ] == [50, 10, 5])
        #expect(child.days.values.allSatisfy { $0[CostUsagePricing.codexUnattributedModel] == nil })
        #expect(child.forkBaselineDependencyKey?.hasPrefix("file|") == true)
    }

    @Test
    func `parent snapshot change invalidates a cached compact child classification`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 17)
        let parentModel = "openai/gpt-5.3"
        let leafModel = "openai/gpt-5.4"
        let prefix: Usage = (input: 1000, cached: 900, output: 100)
        let mismatchedParent: Usage = (input: 999, cached: 899, output: 99)
        let suffix: Usage = (input: 50, cached: 10, output: 5)
        let initialParentContents = try Fixture.parentContents(
            env: env,
            day: day,
            sessionID: "cache-parent",
            model: parentModel,
            totals: mismatchedParent)
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-0-cache-parent.jsonl",
            contents: initialParentContents)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-1-cache-child.jsonl",
            contents: Fixture.childContents(
                env: env,
                day: day,
                fixture: Fixture.Child(
                    sessionID: "cache-child",
                    parentID: "cache-parent",
                    leafModel: leafModel,
                    prefix: prefix,
                    suffix: suffix,
                    preBoundaryLast: nil)))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let before = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let beforeDay = try #require(before.data.first)
        #expect(beforeDay.totalTokens == 2253)
        #expect(beforeDay.modelBreakdowns?.first {
            $0.modelName == CostUsagePricing.codexUnattributedModel
        }?.totalTokens == 1100)
        let beforeCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeChild = try #require(beforeCache.files.values.first { $0.sessionId == "cache-child" })
        let beforeDependency = try #require(beforeChild.forkBaselineDependencyKey)
        #expect(beforeDependency.hasPrefix("file|"))

        let appendedParentSnapshot = try env.jsonl([
            Fixture.tokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(-0.5)),
                model: parentModel,
                total: prefix,
                last: (input: 1, cached: 1, output: 1)),
        ])
        try (initialParentContents + appendedParentSnapshot)
            .write(to: parentURL, atomically: true, encoding: .utf8)

        let after = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let afterDay = try #require(after.data.first)
        #expect(afterDay.totalTokens == 1155)
        #expect(!(afterDay.modelBreakdowns ?? []).contains {
            $0.modelName == CostUsagePricing.codexUnattributedModel
        })
        let afterCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let afterChild = try #require(afterCache.files.values.first { $0.sessionId == "cache-child" })
        #expect(afterChild.forkBaselineDependencyKey?.hasPrefix("file|") == true)
        #expect(afterChild.forkBaselineDependencyKey != beforeDependency)
        #expect(afterChild.days.values.allSatisfy { $0[CostUsagePricing.codexUnattributedModel] == nil })
    }

    @Test
    func `appended first turn marker reclassifies a cached compact child prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 21)
        let parentModel = "openai/gpt-5.4"
        let leafModel = "openai/gpt-5.6-sol"
        let prefix: Usage = (input: 407_555, cached: 399_890, output: 1094)
        let parentOwned: Usage = (input: 127, cached: 125, output: 1)
        let suffix: Usage = (input: 1725, cached: 1568, output: 6)
        let fixture = Fixture.Child(
            sessionID: "growing-compact-child",
            parentID: "growing-compact-parent",
            leafModel: leafModel,
            prefix: prefix,
            suffix: suffix,
            preBoundaryLast: parentOwned)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-0-growing-parent.jsonl",
            contents: Fixture.parentContents(
                env: env,
                day: day,
                sessionID: fixture.parentID,
                model: parentModel,
                totals: prefix,
                lastTotals: parentOwned))
        let prefixContents = try Fixture.childPrefixContents(env: env, day: day, fixture: fixture)
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-1-growing-child.jsonl",
            contents: prefixContents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let provisional = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(provisional.data.first?.modelBreakdowns?.contains {
            $0.modelName == CostUsagePricing.codexUnattributedModel
        } == true)

        let completeContents = try prefixContents
            + Fixture.childSuffixContents(env: env, day: day, fixture: fixture)
        try completeContents.write(to: childURL, atomically: true, encoding: .utf8)

        // A failed full-file read can retain prefix rows while observing the complete file's
        // metadata. `parsedBytes` must keep that cache from becoming permanently fresh.
        var partialCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let partialEntry = try #require(partialCache.files.first { $0.value.sessionId == fixture.sessionID })
        var partialChild = partialEntry.value
        let completeMetadata = CostUsageScanner.codexFileMetadata(fileURL: childURL)
        let parsedPrefixBytes = try #require(partialChild.parsedBytes)
        #expect(parsedPrefixBytes < completeMetadata.size)
        #expect(partialChild.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey)
        partialChild.mtimeUnixMs = completeMetadata.mtimeUnixMs
        partialChild.size = completeMetadata.size
        partialChild.parsedBytes = 0
        partialCache.files[partialEntry.key] = partialChild
        CostUsageCacheIO.save(provider: .codex, cache: partialCache, cacheRoot: env.cacheRoot)

        let completed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let daily = try #require(completed.data.first)
        #expect(daily.totalTokens == 1859)
        #expect(!(daily.modelBreakdowns ?? []).contains {
            $0.modelName == CostUsagePricing.codexUnattributedModel
        })
        #expect(daily.modelBreakdowns?.first {
            $0.modelName == CostUsagePricing.normalizeCodexModel(parentModel)
        }?.totalTokens == 128)
        #expect(daily.modelBreakdowns?.first {
            $0.modelName == CostUsagePricing.normalizeCodexModel(leafModel)
        }?.totalTokens == 1731)
        let refreshedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let refreshedChild = try #require(refreshedCache.files.values.first {
            $0.sessionId == fixture.sessionID
        })
        #expect(refreshedChild.codexForkAttributionVersion == CostUsageScanner.codexForkAttributionVersion)
        #expect(refreshedChild.days.values.allSatisfy {
            $0[CostUsagePricing.codexUnattributedModel] == nil
        })
    }

    @Test
    func `unconfirmed compact prefix stays independent and parent-dependent`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 17)
        let leafModel = "openai/gpt-5.4"
        let prefix: Usage = (input: 1000, cached: 900, output: 100)
        let suffix: Usage = (input: 50, cached: 10, output: 5)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-unconfirmed-child.jsonl",
            contents: Fixture.childContents(
                env: env,
                day: day,
                fixture: Fixture.Child(
                    sessionID: "unconfirmed-child",
                    parentID: "unconfirmed-parent",
                    leafModel: leafModel,
                    prefix: prefix,
                    suffix: suffix,
                    preBoundaryLast: nil)))
        let baselines: [CostUsageScanner.CodexForkBaseline] = [
            .resolved(.init(input: 999, cached: 899, output: 99)),
            .unresolved,
        ]

        for baseline in baselines {
            let parsed = CostUsageScanner.parseCodexFile(
                fileURL: fileURL,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                inheritedTotalsResolver: { _, _ in baseline })
            let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
            #expect(parsed.days[dayKey]?[CostUsagePricing.codexUnattributedModel] == [1000, 900, 100])
            #expect(parsed.days[dayKey]?[CostUsagePricing.normalizeCodexModel(leafModel)] == [50, 10, 5])
            #expect(parsed.dependsOnParentTotals)
        }
    }
}
