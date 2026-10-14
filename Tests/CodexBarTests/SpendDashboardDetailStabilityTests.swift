import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendDashboardDetailStabilityTests {
    @Test
    func `configured native details keep all tabs without rows`() {
        #expect(spendDashboardAvailableDetailSections(
            hasProjects: false,
            hasSessions: false,
            supportsCodexDetails: true)
            == [.providers, .projects, .chats, .sessions])
    }

    @Test
    func `native detail tabs survive another currency publishing first`() {
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner"])
        #expect(spendDashboardCodexDetailPlaceholderCurrency(configuration: configuration, currencyCodes: ["EUR"])
            == "USD")
        #expect(spendDashboardCodexDetailPlaceholderCurrency(configuration: configuration, currencyCodes: []) == "USD")
        #expect(spendDashboardCodexDetailPlaceholderCurrency(configuration: configuration, currencyCodes: ["USD"])
            == nil)
    }

    @Test
    func `OpenCodex replaces totals while native projects and performance survive`() throws {
        let native = Self.input(cost: 8, details: true)
        let replacement = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(cost: 13).snapshot,
            sourceKind: .openCodex)
        let expected = try #require(SpendDashboardModel.build(inputs: [replacement], now: Self.now).groups.first)
        let actual = try #require(SpendDashboardModel.build(
            inputs: [native, replacement],
            now: Self.now,
            hideNativeCodexWhenOpenCodexPresent: true).groups.first)
        #expect(actual.totalCost == expected.totalCost)
        #expect(actual.totalTokens == expected.totalTokens)
        #expect(actual.providers == expected.providers)
        #expect(actual.dailyPoints == expected.dailyPoints)
        #expect(actual.models == expected.models)
        #expect(actual.projects.count == 2)
        #expect(actual.projects.filter(\.isProjectless).count == 1)
        #expect(actual.sessions.first?.turnPerformance?.sampleCount == 1)
        var retained = Self.input(cost: 9, detailsComplete: false)
        retained.retainedDetailSnapshot = native.snapshot
        let retainedGroup = try #require(SpendDashboardModel.build(
            inputs: [retained, replacement],
            now: Self.now,
            hideNativeCodexWhenOpenCodexPresent: true).groups.first)
        #expect(retainedGroup.retainedDetailUpdatedAt == Self.now)
        #expect(retainedGroup.projects.count == 2)
        #expect(retainedGroup.providers == expected.providers)
        let hidden = SpendDashboardModel.build(
            inputs: [native, replacement],
            now: Self.now,
            hiddenSourceIDs: [native.id],
            hideNativeCodexWhenOpenCodexPresent: true)
        #expect(hidden.groups.first?.projects.isEmpty == true)
        let selected = SpendDashboardModel.build(
            inputs: [native, replacement],
            now: Self.now,
            hideNativeCodexWhenOpenCodexPresent: true,
            selectedDay: Self.now.addingTimeInterval(-7 * 86400))
        #expect(selected.groups.first?.projects.isEmpty == true)
        #expect(selected.groups.first?.sessions.count == 1)
        #expect(selected.groups.first?.sessions.first?.turnPerformance == nil)
    }

    @Test
    func `unestablished refresh retains complete totals and details`() async throws {
        let controller = try await Self.refreshed(
            old: Self.input(cost: 8, details: true),
            next: Self.input(cost: 9, complete: false, coverageEstablished: false))
        let group = try #require(controller.model.groups.first)
        #expect(group.totalCost == 8)
        #expect(group.projects.count == 2)
        #expect(group.sessions.first?.turnPerformance?.sampleCount == 1)
    }

    @Test
    func `complete empty refresh clears previous details`() async throws {
        let controller = try await Self.refreshed(old: Self.input(cost: 8, details: true), next: Self.input(cost: 0))
        #expect(controller.model.groups.first?.projects.isEmpty == true)
        #expect(controller.model.groups.first?.sessions.isEmpty == true)
    }

    @Test
    func `established totals without details retain the previous complete projection`() async throws {
        let controller = try await Self.refreshed(
            old: Self.input(cost: 8, details: true),
            next: Self.input(cost: 9, detailsComplete: false))
        #expect(controller.model.groups.first?.totalCost == 9)
        #expect(controller.model.groups.first?.projects.count == 2)
        #expect(controller.model.groups.first?.retainedDetailUpdatedAt == Self.now)
    }

    @Test
    func `details cannot cross history windows`() async throws {
        let controller = try await Self.refreshed(
            old: Self.input(cost: 8, details: true, historyDays: 90),
            next: Self.input(cost: 9, complete: false))
        #expect(controller.model.groups.first?.projects.isEmpty == true)
        #expect(controller.model.groups.first?.retainedDetailUpdatedAt == nil)
    }

    @Test
    func `configured capability respects hidden accounts and survives absent publications`() {
        let visible = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner"])
        let hidden = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner"],
            hiddenSourceIDs: ["codex:account"])
        #expect(visible.supportsCodexDetails)
        #expect(!hidden.supportsCodexDetails)
        #expect(spendDashboardAvailableDetailSections(
            hasProjects: false,
            hasSessions: false,
            supportsCodexDetails: hidden.supportsCodexDetails) == [.providers])
    }

    @Test
    func `details remain scoped to account cache identity and bucket timezone`() {
        let input = Self.input(cost: 8, details: true)
        let configurations = [
            SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: ["account|cache-A"],
                bucketTimeZoneIdentifier: "UTC"),
            SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: ["account|cache-B"],
                bucketTimeZoneIdentifier: "UTC"),
            SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: ["account|cache-A"],
                bucketTimeZoneIdentifier: "America/Los_Angeles"),
        ]
        let scopes = configurations.map { SpendDashboardLoadedInputScope(configuration: $0, input: input) }
        #expect(scopes[0] != scopes[1])
        #expect(scopes[0] != scopes[2])
    }

    @Test
    func `adding an account cannot replace complete details with a totals only cache prime`() async throws {
        let old = Self.input(cost: 8, details: true)
        let partial = Self.input(cost: 9, detailsComplete: false)
        let gate = SpendDashboardPendingLoads<SpendDashboardLoadResult>()
        defer { gate.close() }
        let configuration = DetailConfigurationBox(SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner"],
            bucketTimeZoneIdentifier: "UTC"))
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in .init(
                configuration: configuration.value,
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: Self.now,
                force: false) },
            cachedLoader: { request in .init(
                inputs: request.configuration.codexAccountIdentities.count == 1 ? [old] : [partial],
                failedSourceIDs: []) },
            loader: { _ in await (try? gate.load()) ?? .init(inputs: [], failedSourceIDs: []) },
            nowProvider: { Self.now })
        controller.update(configuration: configuration.value)
        try await gate.waitForPendingCount(1)
        gate.resume(returning: .init(inputs: [old], failedSourceIDs: []))
        try await SpendDashboardStateWait.until(timeout: .seconds(10)) { !controller.isRefreshing }
        configuration.value = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner", "other|owner"],
            bucketTimeZoneIdentifier: "UTC")
        controller.update(configuration: configuration.value)
        try await gate.waitForPendingCount(1)
        #expect(controller.model.groups.first?.projects.count == 2)
        #expect(controller.model.groups.first?.sessions.first?.turnPerformance?.sampleCount == 1)
        gate.resume(returning: .init(inputs: [partial], failedSourceIDs: []))
        try await SpendDashboardStateWait.until(timeout: .seconds(10)) { !controller.isRefreshing }
        #expect(controller.model.groups.first?.projects.count == 2)
    }

    @Test
    func `repeated partial refreshes retain whole sessions and a confirmed empty clears them`() async throws {
        let old = Self.input(cost: 8, details: true)
        let retained = try await Self.refreshed(old: old, next: [
            Self.input(cost: 9, detailsComplete: false),
            Self.input(cost: 10, detailsComplete: false),
        ])
        #expect(retained.model.groups.first?.totalCost == 10)
        #expect(retained.model.groups.first?.sessions.first?.turnPerformance?.sampleCount == 1)
        let cleared = try await Self.refreshed(old: old, next: [
            Self.input(cost: 9, detailsComplete: false),
            Self.input(cost: 0),
            Self.input(cost: 10, detailsComplete: false),
        ])
        #expect(cleared.model.groups.first?.projects.isEmpty == true)
        #expect(cleared.model.groups.first?.retainedDetailUpdatedAt == Self.now)
        #expect(cleared.model.groups.first?.sessions.isEmpty == true)
    }

    @Test
    func `selected day scopes native projects`() {
        let model = SpendDashboardModel.build(
            inputs: [Self.input(cost: 8, details: true)],
            now: Self.now,
            selectedDay: Self.now.addingTimeInterval(-7 * 86400))
        #expect(model.groups.first?.projects.isEmpty == true)
    }

    @Test
    func `replacement totals ignore older native detail history`() {
        let native = Self.input(cost: 8, details: true, day: "2026-07-01")
        let replacement = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.input(cost: 13).snapshot,
            sourceKind: .openCodex)
        let expected = SpendDashboardModel.build(inputs: [replacement], reportingPeriod: .allTime, now: Self.now)
        let actual = SpendDashboardModel.build(
            inputs: [native, replacement],
            reportingPeriod: .allTime,
            now: Self.now,
            hideNativeCodexWhenOpenCodexPresent: true)
        #expect(actual.requestedDays == expected.requestedDays)
        #expect(actual.groups.first?.chartDomain == expected.groups.first?.chartDomain)
    }

    private static func refreshed(
        old: SpendDashboardModel.ProviderInput,
        next: SpendDashboardModel.ProviderInput) async throws -> SpendDashboardController
    {
        try await self.refreshed(old: old, next: [next])
    }

    private static func refreshed(
        old: SpendDashboardModel.ProviderInput,
        next: [SpendDashboardModel.ProviderInput]) async throws -> SpendDashboardController
    {
        let gate = SpendDashboardPendingLoads<SpendDashboardLoadResult>()
        defer { gate.close() }
        let configuration = DetailConfigurationBox(SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: ["codex"],
            codexAccountIdentities: ["account|owner"],
            bucketTimeZoneIdentifier: "UTC"))
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in .init(
                configuration: configuration.value,
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: Self.now,
                force: false) },
            cachedLoader: { _ in .init(inputs: [old], failedSourceIDs: []) },
            loader: { _ in await (try? gate.load()) ?? .init(inputs: [], failedSourceIDs: []) },
            nowProvider: { Self.now })
        for (index, input) in next.enumerated() {
            configuration.value = SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["codex"],
                codexAccountIdentities: ["account|owner"],
                sourceRevisions: ["revision-\(index)"],
                bucketTimeZoneIdentifier: "UTC")
            controller.update(configuration: configuration.value)
            try await gate.waitForPendingCount(1)
            gate.resume(returning: .init(inputs: [input], failedSourceIDs: []))
            try await SpendDashboardStateWait.until(timeout: .seconds(10)) { !controller.isRefreshing }
        }
        return controller
    }

    private nonisolated static let now = Date(timeIntervalSince1970: 1_784_179_200)

    private static func input(
        cost: Double,
        details: Bool = false,
        complete: Bool = true,
        detailsComplete: Bool? = nil,
        coverageEstablished: Bool = true,
        historyDays: Int = 30,
        day: String = "2026-07-15") -> SpendDashboardModel.ProviderInput
    {
        let entry = CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 80,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let projects: [CostUsageProjectBreakdown] = details ? [false, true].map { chat in
            .init(
                name: chat ? "Synthetic chat" : "Synthetic project",
                path: chat ? nil : "/synthetic/project",
                totalTokens: 40,
                totalCostUSD: 4,
                daily: [entry],
                modelBreakdowns: nil,
                isProjectless: chat)
        } : []
        let sample = CostUsageTurnPerformanceSample(
            completedAt: Self.now,
            outputTokens: 40,
            durationMilliseconds: 1000)!
        let sessions: [CostUsageSessionBreakdown] = details ? [.init(
            sessionID: "synthetic",
            lastActivity: Self.now,
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: 40,
            totalTokens: 40,
            requestCount: 1,
            costUSD: 4,
            modelBreakdowns: [],
            turnPerformanceSamples: [sample])] : []
        return .init(id: "codex:account", provider: .codex, displayName: "Synthetic Codex", snapshot: .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: cost == 0 ? 0 : 80,
            last30DaysCostUSD: cost,
            historyDays: historyDays,
            historyCoverageIsEstablished: coverageEstablished,
            historyScanIsPartial: !complete,
            daily: cost == 0 ? [] : [entry],
            projects: projects,
            sessions: sessions,
            detailsAreComplete: detailsComplete ?? complete,
            updatedAt: Self.now))
    }
}

@MainActor
private final class DetailConfigurationBox {
    var value: SpendDashboardConfiguration

    init(_ value: SpendDashboardConfiguration) {
        self.value = value
    }
}
