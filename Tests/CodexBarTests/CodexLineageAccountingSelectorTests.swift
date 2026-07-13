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

    private static func days(input: Int) -> CodexLineageAccountingSelector.PackedDays {
        ["2026-07-09": ["gpt-5.4": [input, 0, 0]]]
    }

    private static func row(input: Int) -> CodexLineageLedger.DailyRow {
        .init(
            day: "2026-07-09",
            model: "gpt-5.4",
            totals: .init(input: input, cached: 0, output: 0),
            costUSD: 0)
    }
}
