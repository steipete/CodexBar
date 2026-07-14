import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageAccountingSelectorTests {
    @Test
    func `legacy and shadow modes keep legacy authority`() {
        let legacy = Self.days(input: 100)
        let primary = [Self.row(input: 40)]
        for mode in [CodexLineageAccountingMode.legacy, .shadow] {
            let selection = CodexLineageAccountingSelector.select(
                mode: mode,
                legacyDays: legacy,
                primaryRows: primary,
                containedFamilies: [.init(documents: [.init(identity: "parent", days: Self.days(input: 20))])])
            #expect(selection.days == legacy)
            #expect(!selection.usedLineageAuthority)
            #expect(selection.containedFamilyCount == 0)
        }
    }

    @Test
    func `lineage mode combines primary and family containment exactly once`() {
        let selection = CodexLineageAccountingSelector.select(
            mode: .lineage,
            authorization: Self.authorization(),
            legacyDays: Self.days(input: 999),
            primaryRows: [Self.row(input: 100)],
            containedFamilies: [
                .init(documents: [
                    .init(identity: "copy", days: Self.days(input: 40)),
                    .init(identity: "copy", days: Self.days(input: 40)),
                ]),
                .init(documents: [.init(identity: "other", days: Self.days(input: 10))]),
            ])

        #expect(selection.usedLineageAuthority)
        #expect(selection.containedFamilyCount == 2)
        #expect(selection.days["2026-07-09"]?["gpt-5.4"]?[0] == 150)
    }

    @Test
    func `contained family uses component envelope instead of summing fork copies`() {
        let first: CodexLineageAccountingSelector.PackedDays = [
            "2026-07-09": ["gpt-5.4": [100, 80, 5]],
        ]
        let copied: CodexLineageAccountingSelector.PackedDays = [
            "2026-07-09": ["gpt-5.4": [100, 60, 8]],
        ]
        let selection = CodexLineageAccountingSelector.select(
            mode: .lineage,
            authorization: Self.authorization(),
            legacyDays: [:],
            primaryRows: [],
            containedFamilies: [.init(documents: [
                .init(identity: "same", days: first),
                .init(identity: "same", days: copied),
            ])])

        #expect(selection.days["2026-07-09"]?["gpt-5.4"] == [100, 80, 8])
    }

    @Test
    func `contained siblings remain additive while physical copies are enveloped`() {
        let selection = CodexLineageAccountingSelector.select(
            mode: .lineage,
            authorization: Self.authorization(),
            legacyDays: [:],
            primaryRows: [],
            containedFamilies: [.init(documents: [
                .init(identity: "child-a", days: Self.days(input: 40)),
                .init(identity: "child-a", days: Self.days(input: 40)),
                .init(identity: "child-b", days: Self.days(input: 10)),
            ])])

        #expect(selection.days["2026-07-09"]?["gpt-5.4"]?[0] == 50)
    }

    @Test
    func `containment copy identity follows physical owner rather than retained metadata`() {
        let first = CostUsageScanner.codexContainedDocumentIdentity(
            scopeID: "home",
            ownerID: "00000000-0000-4000-8000-000000000001")
        let sibling = CostUsageScanner.codexContainedDocumentIdentity(
            scopeID: "home",
            ownerID: "00000000-0000-4000-8000-000000000002")

        #expect(first != sibling)
        #expect(first == CostUsageScanner.codexContainedDocumentIdentity(
            scopeID: "home",
            ownerID: "00000000-0000-4000-8000-000000000001"))
    }

    @Test
    func `mode cache suffixes are schema scoped and distinct`() {
        #expect(CodexLineageAccountingMode.defaultMode == .legacy)
        #expect(CodexLineageAccountingMode.shadow.producerKeySuffix != CodexLineageAccountingMode.lineage
            .producerKeySuffix)
        #expect(CodexLineageAccountingMode.shadow.producerKeySuffix.contains("v1"))
    }

    @Test
    func `scanner defaults to legacy and skips lineage execution`() {
        let options = CostUsageScanner.Options()
        #expect(options.codexLineageAccountingMode == .legacy)
        #expect(!CostUsageScanner.shouldRunCodexLineage(mode: options.codexLineageAccountingMode))
        #expect(CostUsageScanner.shouldRunCodexLineage(mode: .shadow))
        #expect(CostUsageScanner.shouldRunCodexLineage(mode: .lineage))
    }

    @Test
    func `lineage mode without promotion authorization keeps legacy authority`() {
        let legacy = Self.days(input: 100)
        let selection = CodexLineageAccountingSelector.select(
            mode: .lineage,
            legacyDays: legacy,
            primaryRows: [Self.row(input: 999)],
            containedFamilies: [])

        #expect(selection.days == legacy)
        #expect(!selection.usedLineageAuthority)
        #expect(CostUsageScanner.codexAccountingProducerKey(mode: .lineage)
            == CostUsageScanner.codexAccountingProducerKey(mode: .legacy))
        #expect(CostUsageScanner.codexAccountingProducerKey(
            mode: .lineage,
            authorization: Self.authorization()) != CostUsageScanner.codexAccountingProducerKey(mode: .legacy))
    }

    @Test
    func `mode specific producer key mismatch invalidates cache for rollback rebuild`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let shadowKey = CostUsageScanner.codexAccountingProducerKey(mode: .shadow)
        let legacyKey = CostUsageScanner.codexAccountingProducerKey(mode: .legacy)
        var shadowCache = CostUsageCache()
        shadowCache.days = Self.days(input: 100)
        CostUsageCacheIO.save(
            provider: .codex,
            cache: shadowCache,
            cacheRoot: environment.cacheRoot,
            producerKey: shadowKey)

        let rollbackLoad = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: environment.cacheRoot,
            producerKey: legacyKey)
        #expect(rollbackLoad.days.isEmpty)
        #expect(shadowKey != legacyKey)
    }

    @Test
    func `scanner cache follows current lineage authorization and narrowed bounds`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let retainedDay = try environment.makeLocalNoon(year: 2026, month: 7, day: 7)
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 9)
        try Self.writeRollout(
            environment: environment,
            ownerID: "00000000-0000-4000-8000-000000000097",
            day: "2026-07-07",
            inputTokens: 40)
        try Self.writeRollout(
            environment: environment,
            ownerID: "00000000-0000-4000-8000-000000000099",
            day: "2026-07-09",
            inputTokens: 100)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing.sqlite"))
        options.codexLineageAccountingMode = .lineage
        options.codexLineagePromotionAuthorization = Self.authorization()
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: retainedDay,
            until: day,
            now: day,
            options: options)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let authorizedKey = CostUsageScanner.codexAccountingProducerKey(
            mode: .lineage,
            authorization: options.codexLineagePromotionAuthorization)
        let authorizedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: environment.cacheRoot,
            producerKey: authorizedKey)
        let narrowRange = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(authorizedCache.scanSinceKey == narrowRange.scanSinceKey)
        #expect(authorizedCache.scanUntilKey == narrowRange.scanUntilKey)
        #expect(authorizedCache.days["2026-07-07"] == nil)

        options.refreshMinIntervalSeconds = 3600
        let rebuiltRetainedDay = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: retainedDay,
            until: retainedDay,
            now: day,
            options: options)
        #expect(rebuiltRetainedDay.summary?.totalTokens == 45)

        let rebuiltCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: environment.cacheRoot,
            producerKey: authorizedKey)
        let retainedDayRange = CostUsageScanner.CostUsageDayRange(since: retainedDay, until: retainedDay)
        #expect(rebuiltCache.scanSinceKey == retainedDayRange.scanSinceKey)
        #expect(rebuiltCache.scanUntilKey == retainedDayRange.scanUntilKey)
        #expect(rebuiltCache.days["2026-07-07"] != nil)

        options.codexLineagePromotionAuthorization = nil
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let legacyKey = CostUsageScanner.codexAccountingProducerKey(mode: .legacy)
        let rollbackCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: environment.cacheRoot,
            producerKey: legacyKey)
        #expect(rollbackCache.producerKey == legacyKey)
        #expect(!rollbackCache.days.isEmpty)
        #expect(legacyKey != authorizedKey)
    }

    private static func days(input: Int) -> CodexLineageAccountingSelector.PackedDays {
        ["2026-07-09": ["gpt-5.4": [input, 0, 0]]]
    }

    private static func writeRollout(
        environment: CostUsageTestEnvironment,
        ownerID: String,
        day: String,
        inputTokens: Int) throws
    {
        try FileManager.default.createDirectory(at: environment.codexSessionsRoot, withIntermediateDirectories: true)
        let fileURL = environment.codexSessionsRoot
            .appendingPathComponent("rollout-\(day)T12-00-00-\(ownerID).jsonl")
        let contents = [
            #"{"type":"session_meta","payload":{"id":"\#(ownerID)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(day)T12:00:00Z","payload":{"type":"token_count","info":{"#
                + #""last_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":5,"output_tokens":5},"#
                + #""total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":5,"output_tokens":5}}}}"#,
        ].joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func authorization() -> CodexLineagePromotionEvaluator.Authorization {
        let sample = CodexLineageResidualClassifier.Sample(
            day: "2026-07-09",
            referenceTokens: 1000,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: 500,
            ledgerUTCTokens: 950,
            ledgerLocalTokens: 950,
            evidence: .init(localCorpusWasExhaustive: true, duplicateObservationCount: 1))
        let decision = CodexLineagePromotionEvaluator.evaluate(.init(
            residualReport: CodexLineageResidualClassifier.classify(samples: [sample]),
            targetDays: ["2026-07-09"],
            reviewedResidualDays: ["2026-07-09"],
            adversarialGoldensPassed: true,
            boundedDiscoveryPassed: true,
            familyRouting: .init(
                primaryFamilyCount: 1,
                containedFamilyCount: 0,
                doubleContributionFamilyCount: 0,
                permanentContainmentSupported: true),
            performance: .init(
                coldMeasured: true,
                warmMeasured: true,
                memoryBoundMeasured: true,
                hasMaterialRegression: false),
            cancellationStages: Set(CodexLineagePromotionEvaluator.CancellationStage.allCases),
            atomicPublicationPassed: true,
            rollback: .init(legacyWholeScanAvailable: true, rollbackPathVerified: true)))
        return decision.authorization!
    }

    private static func row(input: Int) -> CodexLineageLedger.DailyRow {
        .init(
            day: "2026-07-09",
            model: "gpt-5.4",
            totals: .init(input: input, cached: 0, output: 0),
            costUSD: 0)
    }
}
