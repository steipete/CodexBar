import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct SpendHistoryLedgerTests {
    @Test
    func `merges overlapping windows and persists explicit covered zero days`() async throws {
        let fileURL = Self.tempFileURL()
        let ledger = SpendHistoryLedger(fileURL: fileURL)

        let first = Self.input(
            updatedAt: Self.date("2026-08-10"),
            historyDays: 3,
            aggregate: 5,
            daily: [Self.entry("2026-08-08", cost: 2), Self.entry("2026-08-10", cost: 3)])
        let second = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 3,
            aggregate: 10,
            daily: [
                Self.entry("2026-08-10", cost: 3),
                Self.entry("2026-08-11", cost: 4),
                Self.entry("2026-08-12", cost: 3),
            ])

        _ = await ledger.record(inputs: [first], ownership: ["codex": "owner-a"])
        let snapshots = await ledger.record(inputs: [second], ownership: ["codex": "owner-a"])

        let snapshot = try #require(snapshots.first)
        #expect(snapshot.coveredDayCount == 5)
        #expect(snapshot.hasContinuousCoverage)
        #expect(snapshot.input.trackedCoverage?.coveredDayCount == 5)
        #expect(snapshot.input.snapshot.historyDays == 5)
        #expect(snapshot.input.snapshot.last30DaysCostUSD == 12)
        #expect(snapshot.input.snapshot.daily.map(\.date) == [
            "2026-08-08", "2026-08-09", "2026-08-10", "2026-08-11", "2026-08-12",
        ])
        #expect(snapshot.input.snapshot.daily[1].costUSD == 0)

        let reloaded = SpendHistoryLedger(fileURL: fileURL)
        let persisted = await reloaded.snapshots(
            for: [],
            ownership: ["codex": "owner-a"])
        #expect(persisted.first?.input.snapshot.last30DaysCostUSD == 12)
    }

    @Test
    func `isolates history when source ownership changes`() async {
        let ledger = SpendHistoryLedger(fileURL: Self.tempFileURL())
        let oldInput = Self.input(
            updatedAt: Self.date("2026-08-10"),
            historyDays: 1,
            aggregate: 7,
            daily: [Self.entry("2026-08-10", cost: 7)])
        _ = await ledger.record(inputs: [oldInput], ownership: ["codex": "owner-a"])

        let currentInput = SpendDashboardModel.ProviderInput(
            id: "codex:account",
            provider: .codex,
            displayName: "Codex",
            snapshot: oldInput.snapshot)
        let hidden = await ledger.snapshots(
            for: [currentInput],
            ownership: ["codex:account": "owner-b"])
        #expect(hidden.isEmpty)

        let newSnapshots = await ledger.record(
            inputs: [currentInput],
            ownership: ["codex:account": "owner-b"])
        #expect(newSnapshots.count == 1)
        #expect(newSnapshots.first?.input.snapshot.last30DaysCostUSD == 7)
    }

    @Test
    func `rejects partial or arithmetically inconsistent windows`() async {
        let ledger = SpendHistoryLedger(fileURL: Self.tempFileURL())
        let partial = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 2,
            aggregate: 9,
            established: false,
            daily: [Self.entry("2026-08-12", cost: 9)])
        let inconsistent = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 2,
            aggregate: 9,
            daily: [Self.entry("2026-08-12", cost: 4)])

        let partialResult = await ledger.record(
            inputs: [partial],
            ownership: ["codex": "owner"])
        let inconsistentResult = await ledger.record(
            inputs: [inconsistent],
            ownership: ["codex": "owner"])
        #expect(partialResult.isEmpty)
        #expect(inconsistentResult.isEmpty)
    }

    @Test
    func `preserves model breakdowns across launches`() async throws {
        let fileURL = Self.tempFileURL()
        let input = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 1,
            aggregate: 2.5,
            daily: [Self.entry("2026-08-12", cost: 2.5, model: "gpt-5")])
        _ = await SpendHistoryLedger(fileURL: fileURL).record(
            inputs: [input],
            ownership: ["codex": "owner"])

        let snapshots = await SpendHistoryLedger(fileURL: fileURL).snapshots(
            for: [input],
            ownership: ["codex": "owner"])
        let model = try #require(snapshots.first?.input.snapshot.daily.first?.modelBreakdowns?.first)
        #expect(model.modelName == "gpt-5")
        #expect(model.costUSD == 2.5)
    }

    @Test
    func `recovers from a corrupt persisted document`() async throws {
        let fileURL = Self.tempFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL, options: [.atomic])
        let input = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 1,
            aggregate: 1,
            daily: [Self.entry("2026-08-12", cost: 1)])

        let snapshots = await SpendHistoryLedger(fileURL: fileURL).record(
            inputs: [input],
            ownership: ["codex": "owner"])

        #expect(snapshots.count == 1)
        let data = try Data(contentsOf: fileURL)
        #expect(String(bytes: data, encoding: .utf8)?.contains("\"version\" : 1") == true)
    }

    @Test
    func `derives typed provider and codex ownership scopes`() {
        let scopes = SpendHistoryLedger.ownershipScopes(
            sourceOwnershipFingerprints: ["claude:config:scope:account"],
            codexAccountIdentities: ["account:with:colons|cache-identity"])

        #expect(scopes["claude"] == "claude:config:scope:account")
        #expect(scopes["codex:account:with:colons"] == "account:with:colons|cache-identity")
    }

    #if os(macOS)
    @Test
    func `persists history with owner-only permissions`() async throws {
        let fileURL = Self.tempFileURL()
        let input = Self.input(
            updatedAt: Self.date("2026-08-12"),
            historyDays: 1,
            aggregate: 1,
            daily: [Self.entry("2026-08-12", cost: 1)])
        _ = await SpendHistoryLedger(fileURL: fileURL).record(
            inputs: [input],
            ownership: ["codex": "owner"])

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }
    #endif

    private static func input(
        updatedAt: Date,
        historyDays: Int,
        aggregate: Double,
        established: Bool = true,
        daily: [CostUsageDailyReport.Entry]) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: daily.compactMap(\.totalTokens).reduce(0, +),
                last30DaysCostUSD: aggregate,
                historyDays: historyDays,
                historyCoverageIsEstablished: established,
                daily: daily,
                updatedAt: updatedAt))
    }

    private static func entry(
        _ day: String,
        cost: Double,
        model: String? = nil) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: 1,
            outputTokens: 2,
            totalTokens: 3,
            costUSD: cost,
            modelsUsed: model.map { [$0] },
            modelBreakdowns: model.map {
                [CostUsageDailyReport.ModelBreakdown(modelName: $0, costUSD: cost, totalTokens: 3)]
            })
    }

    private static func date(_ day: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendHistoryLedgerTests-\(UUID().uuidString)")
            .appendingPathComponent("spend-history.json")
    }
}
