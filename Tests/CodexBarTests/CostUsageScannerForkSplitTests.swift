import Foundation
#if canImport(SQLite3)
import Testing
@testable import CodexBarCore

struct CostUsageScannerForkSplitTests {
    @Test
    func `codex report preserves short request pricing after copied fork prefix`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let projectPath = "/tmp/codexbar-fork-tier-project"
        let parentRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "parent-turn",
            eventIndex: 0,
            timestampUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            input: 200_000,
            cached: 0,
            output: 100)
        let childRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "child-turn",
            eventIndex: 1,
            timestampUnixMs: Int64(day.addingTimeInterval(1).timeIntervalSince1970 * 1000),
            input: 200_000,
            cached: 0,
            output: 100)
        let parentUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: parentRow.timestampUnixMs ?? 0,
            size: 1,
            days: [dayKey: [model: [200_000, 0, 100]]],
            parsedBytes: 1,
            sessionId: "parent-session",
            projectPath: projectPath,
            canonicalProjectPath: projectPath,
            codexRows: [parentRow],
            codexScanComplete: true)
        let childUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: childRow.timestampUnixMs ?? 0,
            size: 1,
            days: [dayKey: [model: [200_000, 0, 100]]],
            parsedBytes: 1,
            sessionId: "child-session",
            forkedFromId: "parent-session",
            projectPath: projectPath,
            canonicalProjectPath: projectPath,
            codexRows: [parentRow, childRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/parent.jsonl": parentUsage, "/child.jsonl": childUsage]
        cache.days = [dayKey: [model: [400_000, 0, 200]]]
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let requestCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 200_000,
            cachedInputTokens: 0,
            outputTokens: 100))
        let aggregateCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 400_000,
            cachedInputTokens: 0,
            outputTokens: 200))
        let reportCost = try #require(report.summary?.totalCostUSD)
        let requestCostSum = requestCost * 2

        #expect(abs(reportCost - requestCostSum) < 1e-12)
        #expect(aggregateCost > requestCostSum * 1.9)
        #expect(abs(reportCost - aggregateCost) > 0.9)

        let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(cache: cache, range: range)
        let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(cache: cache, range: range)
        #expect(abs(projects.compactMap(\.totalCostUSD).reduce(0, +) - reportCost) < 1e-12)
        #expect(abs(sessions.compactMap(\.costUSD).reduce(0, +) - reportCost) < 1e-12)

        let predecessorHash = "43609cc56f76a003"
        let predecessorStore = CostUsageStore(
            cacheRoot: environment.cacheRoot,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion,
                parserHash: predecessorHash),
            parserHash: predecessorHash)
        _ = predecessorStore.syncSaveCodexCache(
            cache,
            calendar: range.calendar,
            requestedScanWindow: (sinceKey: dayKey, untilKey: dayKey))
        let currentStore = CostUsageStore(cacheRoot: environment.cacheRoot)
        let restored = currentStore.syncLoadCodexCache(calendar: range.calendar)
        let warmReport = CostUsageScanner.buildCodexReportFromCache(cache: restored, range: range)
        #expect(await currentStore.rebuildCount == 0)
        #expect(restored.files.values.flatMap { $0.codexRows ?? [] }.count == 3)
        #expect(warmReport.data == report.data)
        #expect(warmReport.summary == report.summary)
    }

    @Test
    func `codex report applies long context pricing only to the genuine long request`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let timestamp = Int64(day.timeIntervalSince1970 * 1000)
        let longRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "long-turn",
            eventIndex: 0,
            timestampUnixMs: timestamp,
            input: 300_000,
            cached: 0,
            output: 100,
            reasoning: 50,
            pricingModel: model,
            pricingMode: "standard")
        let shortRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "short-turn",
            eventIndex: 1,
            timestampUnixMs: timestamp + 1,
            input: 100_000,
            cached: 0,
            output: 100,
            reasoning: 25,
            pricingModel: model,
            pricingMode: "standard")
        let trailingZeroRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "short-turn",
            eventIndex: 2,
            timestampUnixMs: timestamp + 2,
            input: 0,
            cached: 0,
            output: 0,
            reasoning: 0,
            pricingModel: model,
            pricingMode: "standard")
        let parentUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: timestamp,
            size: 1,
            days: [dayKey: [model: [300_000, 0, 100]]],
            parsedBytes: 1,
            sessionId: "long-session",
            codexRows: [longRow],
            codexScanComplete: true)
        let childUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: timestamp + 2,
            size: 1,
            days: [dayKey: [model: [100_000, 0, 100]]],
            parsedBytes: 1,
            sessionId: "short-session",
            forkedFromId: "long-session",
            codexRows: [longRow, shortRow, trailingZeroRow],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/long.jsonl": parentUsage, "/short.jsonl": childUsage]
        cache.days = [dayKey: [model: [400_000, 0, 200]]]

        let reconciledChild = CostUsageScanner.codexCanonicalPricingRows(childUsage)
        #expect(reconciledChild.unresolvedGroups.isEmpty)
        #expect(reconciledChild.rows == [shortRow, trailingZeroRow])

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let longCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 150))
        let shortCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 125))
        let aggregateCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 400_000,
            cachedInputTokens: 0,
            outputTokens: 200))

        #expect(abs((report.summary?.totalCostUSD ?? 0) - (longCost + shortCost)) < 1e-2)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - aggregateCost) > 0.4)
    }

    @Test
    func `codex report leaves threshold cost unavailable without exact request rows`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        func row(index: Int, input: Int) -> CostUsageScanner.CodexUsageRow {
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: model,
                turnID: "turn-\(index)",
                eventIndex: index,
                timestampUnixMs: Int64(index),
                input: input,
                cached: 0,
                output: 0,
                knownCostNanos: 42_000_000_000)
        }

        var usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [400_000, 0, 0]]],
            parsedBytes: 1,
            sessionId: "irreconcilable",
            codexCostNanos: [dayKey: [model: 84_000_000_000]],
            codexRows: [row(index: 0, input: 220_000), row(index: 1, input: 220_000)],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/irreconcilable.jsonl": usage]
        cache.days = usage.days

        let irreconcilable = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(irreconcilable.summary?.totalTokens == 400_000)
        #expect(irreconcilable.summary?.totalCostUSD == nil)

        usage.codexRows = nil
        cache.files = ["/aggregate-only.jsonl": usage]
        let aggregateOnly = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(aggregateOnly.summary?.totalTokens == 400_000)
        #expect(aggregateOnly.summary?.totalCostUSD == nil)

        usage.days = [dayKey: [model: [200_000, 0, 0]]]
        usage.codexRows = nil
        cache.files = ["/below-threshold.jsonl": usage]
        cache.days = usage.days
        let belowThreshold = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let belowThresholdCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 200_000,
            cachedInputTokens: 0,
            outputTokens: 0))
        #expect(abs((belowThreshold.summary?.totalCostUSD ?? 0) - belowThresholdCost) < 1e-12)
    }

    @Test
    func `codex report safely prices linear aggregate fallback`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }

        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.4-mini"
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [400_000, 100_000, 100]]],
            parsedBytes: 1,
            sessionId: "linear-aggregate",
            codexRows: nil,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/linear.jsonl": usage]
        cache.days = usage.days

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let expected = try #require(CostUsagePricing.codexAggregateCostUSD(
            model: model,
            inputTokens: 400_000,
            cachedInputTokens: 100_000,
            outputTokens: 100))

        #expect(abs((report.summary?.totalCostUSD ?? 0) - expected) < 1e-12)

        var priorityUsage = usage
        priorityUsage.codexPriorityTokens = [dayKey: [model: 400_100]]
        cache.files = ["/linear-priority.jsonl": priorityUsage]
        let priorityAggregate = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(priorityAggregate.summary?.totalTokens == 400_100)
        #expect(priorityAggregate.summary?.totalCostUSD == nil)

        priorityUsage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "legacy-mode-less-turn",
            eventIndex: 0,
            timestampUnixMs: 1,
            input: 400_000,
            cached: 100_000,
            output: 100)]
        cache.files = ["/linear-mode-mismatch.jsonl": priorityUsage]
        let modeMismatch = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(modeMismatch.summary?.totalTokens == 400_100)
        #expect(modeMismatch.summary?.totalCostUSD == nil)
    }

    @Test
    func `exact codex pricing rows retain persisted order`() {
        let dayKey = "2026-08-11"
        let model = "gpt-5.6-sol"
        let later = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "later",
            eventIndex: 1,
            timestampUnixMs: 2,
            input: 20,
            cached: 2,
            output: 2)
        let earlier = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "earlier",
            eventIndex: 0,
            timestampUnixMs: 1,
            input: 10,
            cached: 1,
            output: 1)
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [30, 3, 3]]],
            parsedBytes: 1,
            codexRows: [later, earlier],
            codexScanComplete: true)

        let reconciled = CostUsageScanner.codexCanonicalPricingRows(usage)
        #expect(reconciled.unresolvedGroups.isEmpty)
        #expect(reconciled.rows == [later, earlier])
    }

    @Test
    func `copied fast prefix with later timestamp cannot replace persisted standard suffix`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let parent = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "fast-parent",
            eventIndex: 0,
            timestampUnixMs: 2,
            input: 100_000,
            cached: 0,
            output: 10,
            pricingMode: "priority")
        let child = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "standard-child",
            eventIndex: 1,
            timestampUnixMs: 1,
            input: 100_000,
            cached: 0,
            output: 10,
            pricingMode: "standard")
        let parentUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [100_000, 0, 10]]],
            parsedBytes: 1,
            sessionId: "parent",
            codexRows: [parent],
            codexScanComplete: true)
        let childUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [100_000, 0, 10]]],
            parsedBytes: 1,
            sessionId: "child",
            forkedFromId: "parent",
            codexRows: [parent, child],
            codexScanComplete: true)
        let reconciled = CostUsageScanner.codexCanonicalPricingRows(childUsage)
        #expect(reconciled.unresolvedGroups.isEmpty)
        #expect(reconciled.rows == [child])

        var cache = CostUsageCache()
        cache.files = ["/parent.jsonl": parentUsage, "/child.jsonl": childUsage]
        cache.days = [dayKey: [model: [200_000, 0, 20]]]
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        let standardCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 10))
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: model,
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 10))
        #expect(abs((breakdown.standardCostUSD ?? 0) - standardCost) < 1e-12)
        #expect(abs((breakdown.priorityCostUSD ?? 0) - priorityCost) < 1e-12)
        #expect(breakdown.standardTokens == 100_010)
        #expect(breakdown.priorityTokens == 100_010)
    }

    @Test
    func `zero owned fork rows use an empty suffix without hiding parent cost`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let parentRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "parent",
            eventIndex: 0,
            timestampUnixMs: 1,
            input: 300_000,
            cached: 0,
            output: 10)
        let parentUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [300_000, 0, 10]]],
            parsedBytes: 1,
            sessionId: "parent",
            codexRows: [parentRow],
            codexScanComplete: true)
        let childUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [0, 0, 0]]],
            parsedBytes: 1,
            sessionId: "zero-child",
            forkedFromId: "parent",
            codexRows: [parentRow],
            codexScanComplete: true)
        let reconciled = CostUsageScanner.codexCanonicalPricingRows(childUsage)
        #expect(reconciled.rows.isEmpty)
        #expect(reconciled.unresolvedGroups.isEmpty)

        var cache = CostUsageCache()
        cache.files = ["/parent.jsonl": parentUsage, "/child.jsonl": childUsage]
        cache.days = parentUsage.days
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let expected = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 10))
        #expect(abs((report.summary?.totalCostUSD ?? 0) - expected) < 1e-12)
    }

    @Test
    func `exact rows require complete request pricing coverage`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let priced = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "priced",
            eventIndex: 0,
            input: 100_000,
            cached: 0,
            output: 10,
            pricingModel: model)
        let unpriced = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "unpriced",
            eventIndex: 1,
            input: 100_000,
            cached: 0,
            output: 10,
            unpricedTokens: 100_010,
            pricingModel: "unpriced-test-model")
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [200_000, 0, 20]]],
            parsedBytes: 1,
            codexRows: [priced, unpriced],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/partial-pricing.jsonl": usage]
        cache.days = usage.days
        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(report.data.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)

        let authoritativeZero = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "authoritative-zero",
            eventIndex: 2,
            input: 0,
            cached: 0,
            output: 0,
            knownCostNanos: 42_000_000_000)
        let completeUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [100_000, 0, 10]]],
            parsedBytes: 1,
            codexRows: [priced, authoritativeZero],
            codexScanComplete: true)
        cache.files = ["/complete-pricing.jsonl": completeUsage]
        cache.days = completeUsage.days
        let complete = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        let pricedCost = try #require(CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 10))
        #expect(abs((complete.summary?.totalCostUSD ?? 0) - (pricedCost + 42)) < 1e-12)
    }

    @Test
    func `project primary report propagates unresolved same model ownership`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let model = "gpt-5.6-sol"
        let projectPath = "/tmp/codexbar-unresolved-project"
        let exactRow = CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            turnID: "exact",
            eventIndex: 0,
            input: 300_000,
            cached: 0,
            output: 10)
        func unresolvedRow(_ index: Int) -> CostUsageScanner.CodexUsageRow {
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: model,
                turnID: "unresolved-\(index)",
                eventIndex: index,
                input: 220_000,
                cached: 0,
                output: 5)
        }
        let exactUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [dayKey: [model: [300_000, 0, 10]]],
            parsedBytes: 1,
            sessionId: "exact",
            projectPath: projectPath,
            canonicalProjectPath: projectPath,
            codexRows: [exactRow],
            codexScanComplete: true)
        let unresolvedUsage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 2,
            size: 1,
            days: [dayKey: [model: [400_000, 0, 10]]],
            parsedBytes: 1,
            sessionId: "unresolved",
            projectPath: projectPath,
            canonicalProjectPath: projectPath,
            codexRows: [unresolvedRow(1), unresolvedRow(2)],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files = ["/exact.jsonl": exactUsage, "/unresolved.jsonl": unresolvedUsage]
        cache.days = [dayKey: [model: [700_000, 0, 20]]]
        let global = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: range)
        #expect(global.data.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(global.summary?.totalCostUSD == nil)

        let project = try #require(CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: cache,
            range: range).first)
        #expect(project.path == projectPath)
        #expect(project.modelBreakdowns?.first?.costUSD == nil)
        #expect(project.totalCostUSD == nil)
        #expect(project.totalTokens == 700_020)
    }

    @Test
    func `project primary report keeps priced models beside explicitly unpriced models`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let dayKey = range.sinceKey
        let pricedModel = "gpt-5.6-sol"
        let unpricedModel = "codex-auto-review"
        let projectPath = "/tmp/codexbar-partial-project"
        func usage(model: String, input: Int, path: String) -> (String, CostUsageFileUsage) {
            let row = CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: model,
                turnID: path,
                eventIndex: 0,
                input: input,
                cached: 0,
                output: 10,
                pricingModel: model)
            return (path, CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 1,
                days: [dayKey: [model: [input, 0, 10]]],
                parsedBytes: 1,
                sessionId: path,
                projectPath: projectPath,
                canonicalProjectPath: projectPath,
                codexRows: [row],
                codexScanComplete: true))
        }
        let priced = usage(model: pricedModel, input: 100_000, path: "/priced.jsonl")
        let unpriced = usage(model: unpricedModel, input: 50000, path: "/unpriced.jsonl")
        var cache = CostUsageCache()
        cache.files = [priced.0: priced.1, unpriced.0: unpriced.1]
        cache.days = [
            dayKey: [pricedModel: [100_000, 0, 10], unpricedModel: [50000, 0, 10]],
        ]
        let expected = try #require(CostUsagePricing.codexCostUSD(
            model: pricedModel,
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 10))

        let project = try #require(CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: cache,
            range: range).first)
        #expect(abs((project.totalCostUSD ?? 0) - expected) < 1e-12)
        #expect(project.modelBreakdowns?.first { $0.modelName == pricedModel }?.costUSD == expected)
        #expect(project.modelBreakdowns?.first { $0.modelName == unpricedModel }?.costUSD == nil)
    }

    @Test
    func `codex report reconciles copied fork prefix without losing fast split`() throws {
        let fixture = try self.makeFixture()
        defer { fixture.environment.cleanup() }

        var cache = fixture.cache
        let parent = try #require(cache.files.first { $0.value.sessionId == "parent-session" })
        let child = try #require(cache.files.first { $0.value.sessionId == "child-session" })
        let copiedParentRows = try #require(parent.value.codexRows)
        var inflatedChild = child.value
        inflatedChild.codexRows = copiedParentRows + (inflatedChild.codexRows ?? [])
        cache.files[child.key] = inflatedChild

        let canonical = try #require(cache.days[fixture.dayKey]?[fixture.model])
        #expect(canonical == [150, 60, 15])
        let canonicalTokens = canonical[0] + canonical[2]
        let rowTokens = cache.files.values
            .flatMap { $0.codexRows ?? [] }
            .reduce(0) { $0 + $1.input + $1.output }
        #expect(rowTokens > canonicalTokens)

        let report = CostUsageScanner.buildCodexReportFromCache(cache: cache, range: fixture.range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        let standardCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 50,
            cachedInputTokens: 20,
            outputTokens: 5))
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: fixture.model,
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 10))

        #expect(abs((breakdown.costUSD ?? 0) - (standardCost + priorityCost)) < 1e-12)
        #expect(abs((breakdown.standardCostUSD ?? 0) - standardCost) < 1e-12)
        #expect(abs((breakdown.priorityCostUSD ?? 0) - priorityCost) < 1e-12)
        #expect(breakdown.standardTokens == 55)
        #expect(breakdown.priorityTokens == 110)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - (standardCost + priorityCost)) < 1e-12)
    }

    @Test
    func `codex report keeps trusted fork deduplicated row split`() throws {
        let fixture = try self.makeFixture()
        defer { fixture.environment.cleanup() }

        let canonical = try #require(fixture.cache.days[fixture.dayKey]?[fixture.model])
        #expect(canonical == [150, 60, 15])
        let child = try #require(fixture.cache.files.first { $0.value.sessionId == "child-session" }?.value)
        #expect(child.days[fixture.dayKey]?[fixture.model] == [50, 20, 5])

        let report = CostUsageScanner.buildCodexReportFromCache(cache: fixture.cache, range: fixture.range)
        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        let standardCost = try #require(CostUsagePricing.codexCostUSD(
            model: fixture.model,
            inputTokens: 50,
            cachedInputTokens: 20,
            outputTokens: 5))
        let priorityCost = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: fixture.model,
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 10))

        #expect(abs((breakdown.costUSD ?? 0) - (standardCost + priorityCost)) < 1e-12)
        #expect(abs((breakdown.standardCostUSD ?? 0) - standardCost) < 1e-12)
        #expect(abs((breakdown.priorityCostUSD ?? 0) - priorityCost) < 1e-12)
        #expect(breakdown.standardTokens == 55)
        #expect(breakdown.priorityTokens == 110)
    }

    private struct Fixture {
        let environment: CostUsageTestEnvironment
        let range: CostUsageScanner.CostUsageDayRange
        let dayKey: String
        let model: String
        let cache: CostUsageCache
    }

    private func makeFixture() throws -> Fixture {
        let env = try CostUsageTestEnvironment()
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 6)
        let parentTimestamp = env.isoString(for: day)
        let parentUsageTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childUsageTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let model = "gpt-5.5"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "a-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": parentTimestamp,
                    "payload": ["id": "parent-session", "timestamp": parentTimestamp],
                ],
                ["type": "turn_context", "timestamp": parentTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": parentUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "priority-turn"],
                ],
                self.totalTokenCount(timestamp: parentUsageTimestamp, input: 100, cached: 40, output: 10),
            ]))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "z-child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkTimestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": forkTimestamp,
                    ],
                ],
                ["type": "turn_context", "timestamp": forkTimestamp, "payload": ["model": model]],
                [
                    "type": "event_msg",
                    "timestamp": childUsageTimestamp,
                    "payload": ["type": "task_started", "turn_id": "standard-turn"],
                ],
                self.totalTokenCount(timestamp: childUsageTimestamp, input: 150, cached: 60, output: 15),
            ]))

        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: parentUsageTimestamp,
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL,
            forceRescan: true,
            preferNewestCodexSessionsFirst: false)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        return Fixture(
            environment: env,
            range: range,
            dayKey: range.sinceKey,
            model: model,
            cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: range.calendar))
    }

    private func totalTokenCount(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }
}
#endif
