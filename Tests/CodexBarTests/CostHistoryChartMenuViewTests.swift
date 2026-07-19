import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CostHistoryChartMenuViewTests {
    @Test
    func `Codex chart explains that its token estimate is not a subscription bill`() {
        #expect(
            CostHistoryChartMenuView.estimateDisclaimer(provider: .codex)
                == "Estimated from token usage · not a subscription bill")
        #expect(CostHistoryChartMenuView.estimateDisclaimer(provider: .claude) == nil)
    }

    @Test
    @MainActor
    func `model breakdown keeps every item behind a bounded scrolling viewport`() {
        let breakdown = (1...6).map { index in
            CostUsageDailyReport.ModelBreakdown(
                modelName: "model-\(index)",
                costUSD: Double(index),
                totalTokens: index * 100)
        }

        let ordered = CostHistoryChartMenuView.orderedBreakdownItems(breakdown)

        #expect(ordered.map(\.modelName) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: ordered.count) == 4)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: ordered.count))
        #expect(CostHistoryChartMenuView.detailOverflowHint(itemCount: ordered.count) == "Scroll to see more models")
        #expect(CostHistoryChartMenuView.detailOverflowHint(itemCount: 4) == nil)
    }

    @Test
    @MainActor
    func `menu hosting view publishes measured height through intrinsic size`() {
        let hosting = MenuHostingView(rootView: EmptyView())
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 1)

        hosting.applyMeasuredHeight(width: 320, height: 123.2)

        #expect(hosting.frame.size == CGSize(width: 320, height: 124))
        #expect(hosting.intrinsicContentSize.height == 124)
    }

    @Test
    @MainActor
    func `cost history defaults selection to latest day`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-07",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 1.25,
                modelsUsed: ["gpt-5.5"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-06-09",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 2.5,
                modelsUsed: ["gpt-5.5"],
                modelBreakdowns: nil),
        ]

        #expect(
            CostHistoryChartMenuView._defaultSelectedDateKeyForTesting(
                provider: .codex,
                daily: daily) == "2026-06-09")
    }

    @Test
    @MainActor
    func `cost history sizes its viewport to the largest breakdown in the range`() {
        let threeRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 1), Self.entry(date: "2026-06-08", modelCount: 3)])
        let cappedRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 6)])
        let mixedRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 6), Self.entry(date: "2026-06-08", modelCount: 1)])
        let noRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 0)])

        #expect(threeRows.rowCount == 3)
        #expect(!threeRows.hasOverflow)
        #expect(threeRows.rowHeight == 36)
        #expect(cappedRows.rowCount == 4)
        #expect(cappedRows.hasOverflow)
        #expect(mixedRows.rowCount == 4)
        #expect(mixedRows.hasOverflow)
        #expect(noRows.rowCount == 0)
        #expect(!noRows.hasOverflow)
    }

    @Test
    @MainActor
    func `cost history expands every row only when the range contains mode details`() {
        let compact = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 2)])
        let expanded = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [
                Self.entry(date: "2026-06-07", modelCount: 2),
                Self.entry(date: "2026-06-08", modelCount: 1, hasModeDetails: true),
            ])

        #expect(compact.rowHeight == 36)
        #expect(expanded.rowHeight == 44)
        #expect(compact.rowCount == expanded.rowCount)
    }

    @Test
    @MainActor
    func `axis dates span first to last for multi-day data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-05-21",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 1.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 2.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        let cal = Calendar.current
        #expect(dates.count == 2)
        #expect(cal.component(.month, from: dates[0]) == 5)
        #expect(cal.component(.day, from: dates[0]) == 21)
        #expect(cal.component(.month, from: dates[1]) == 6)
        #expect(cal.component(.day, from: dates[1]) == 17)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .edges)
    }

    @Test
    @MainActor
    func `axis dates collapse to one for single-day data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 1.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        #expect(dates.count == 1)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .centered)
    }

    @Test
    @MainActor
    func `axis dates are empty when there is no cost data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        #expect(dates.isEmpty)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .hidden)
    }

    @Test
    @MainActor
    func `y-axis tick values are empty for flat or no data`() {
        #expect(CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 0).isEmpty)
        #expect(CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: -1).isEmpty)
    }

    @Test
    @MainActor
    func `y-axis tick values use two ticks for small ranges`() {
        let ticks = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 0.50)
        #expect(ticks == [0, 0.50])
    }

    @Test
    @MainActor
    func `y-axis tick values use three ticks for ranges at or above one dollar`() {
        let ticks = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 12.0)
        #expect(ticks == [0, 6.0, 12.0])

        let large = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 1000.0)
        #expect(large == [0, 500.0, 1000.0])
    }

    @Test(arguments: [
        (0.0, "$0"),
        (12.56, "$13"),
        (0.50, "$0.50"),
    ])
    @MainActor
    func `y-axis cost labels preserve cents only for nonzero sub-dollar values`(
        value: Double,
        expected: String)
    {
        #expect(CostHistoryChartMenuView._yAxisCostStringForTesting(value) == expected)
    }

    @Test
    @MainActor
    func `cost history fitting height stays stable across compact overflow and mode selections`() {
        let compactLatestHasOneModel = [
            Self.entry(date: "2026-06-07", modelCount: 3),
            Self.entry(date: "2026-06-08", modelCount: 1),
        ]
        let compactLatestHasThreeModels = [
            Self.entry(date: "2026-06-07", modelCount: 1),
            Self.entry(date: "2026-06-08", modelCount: 3),
        ]
        let overflowLatestHasFourModels = [
            Self.entry(date: "2026-06-07", modelCount: 6),
            Self.entry(date: "2026-06-08", modelCount: 4),
        ]
        let overflowLatestHasSixModels = [
            Self.entry(date: "2026-06-07", modelCount: 4),
            Self.entry(date: "2026-06-08", modelCount: 6),
        ]
        let modeLatestHasOneModel = [
            Self.entry(date: "2026-06-07", modelCount: 6),
            Self.entry(date: "2026-06-08", modelCount: 1, hasModeDetails: true),
        ]
        let modeLatestHasSixModels = [
            Self.entry(date: "2026-06-07", modelCount: 1, hasModeDetails: true),
            Self.entry(date: "2026-06-08", modelCount: 6),
        ]

        let compactHeight = Self.renderedHeight(daily: compactLatestHasOneModel)
        let overflowHeight = Self.renderedHeight(daily: overflowLatestHasFourModels)
        let modeHeight = Self.renderedHeight(daily: modeLatestHasOneModel)

        #expect(compactHeight == Self.renderedHeight(daily: compactLatestHasThreeModels))
        #expect(overflowHeight == Self.renderedHeight(daily: overflowLatestHasSixModels))
        #expect(modeHeight == Self.renderedHeight(daily: modeLatestHasSixModels))
        #expect(compactHeight < overflowHeight)
        #expect(overflowHeight < modeHeight)
    }

    @Test
    @MainActor
    func `cost history without model breakdown stays compact`() {
        let noBreakdown = [Self.entry(date: "2026-06-07", modelCount: 0)]
        let withBreakdown = [Self.entry(date: "2026-06-07", modelCount: 1)]

        #expect(Self.renderedHeight(daily: noBreakdown) < Self.renderedHeight(daily: withBreakdown))
    }

    @Test
    @MainActor
    func `single differing project source remains visible`() {
        let matching = Self.project(path: "/tmp/main", sourcePath: "/tmp/main")
        let differing = Self.project(path: "/tmp/main", sourcePath: "/tmp/worktree")

        #expect(CostHistoryChartMenuView.visibleProjectSources(matching).isEmpty)
        #expect(CostHistoryChartMenuView.visibleProjectSources(differing).compactMap(\.path) == ["/tmp/worktree"])
    }

    @Test
    @MainActor
    func `render fingerprint is stable for identical snapshots`() {
        let snapshot = Self.makeSnapshot(dailyCost: 1.23, projectCount: 5)
        let first = CostHistoryChartMenuView.renderFingerprint(from: snapshot, provider: .codex)
        let second = CostHistoryChartMenuView.renderFingerprint(from: snapshot, provider: .codex)

        #expect(first == second)
        #expect(first.projects.count == 5)
        #expect(first.projects.allSatisfy { $0.sources.count <= 2 })
    }

    @Test
    @MainActor
    func `render fingerprint changes when daily cost changes`() {
        let before = CostHistoryChartMenuView.renderFingerprint(
            from: Self.makeSnapshot(dailyCost: 1.0),
            provider: .codex)
        let after = CostHistoryChartMenuView.renderFingerprint(
            from: Self.makeSnapshot(dailyCost: 2.0),
            provider: .codex)

        #expect(before != after)
    }

    @Test
    @MainActor
    func `render fingerprint changes for total currency history window and label`() {
        let base = Self.makeSnapshot(dailyCost: 1.0)
        #expect(
            CostHistoryChartMenuView.renderFingerprint(from: base, provider: .codex)
                != CostHistoryChartMenuView.renderFingerprint(from: Self.makeSnapshot(
                    dailyCost: 1.0,
                    totalCostUSD: 9.99), provider: .codex))
        #expect(
            CostHistoryChartMenuView.renderFingerprint(from: base, provider: .codex)
                != CostHistoryChartMenuView.renderFingerprint(from: Self.makeSnapshot(
                    dailyCost: 1.0,
                    currencyCode: "EUR"), provider: .codex))
        #expect(
            CostHistoryChartMenuView.renderFingerprint(from: base, provider: .codex)
                != CostHistoryChartMenuView.renderFingerprint(from: Self.makeSnapshot(
                    dailyCost: 1.0,
                    historyDays: 7), provider: .codex))
        #expect(
            CostHistoryChartMenuView.renderFingerprint(from: base, provider: .codex)
                != CostHistoryChartMenuView.renderFingerprint(from: Self.makeSnapshot(
                    dailyCost: 1.0,
                    historyLabel: "Last week"), provider: .codex))
    }

    @Test
    @MainActor
    func `render fingerprint tracks daily token request and model breakdown fields`() {
        let baseDaily = [Self.entry(date: "2026-06-07", modelCount: 1)]
        let base = Self.fingerprint(dailyCost: 1.0, daily: baseDaily, projects: [])

        var changedTokens = baseDaily
        changedTokens[0] = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 999,
            costUSD: 1,
            modelsUsed: ["model-0"],
            modelBreakdowns: changedTokens[0].modelBreakdowns)
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: changedTokens, projects: []))

        var changedRequests = baseDaily
        changedRequests[0] = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            requestCount: 42,
            costUSD: 1,
            modelsUsed: ["model-0"],
            modelBreakdowns: changedRequests[0].modelBreakdowns)
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: changedRequests, projects: []))

        let changedModel = [
            Self.entry(date: "2026-06-07", modelCount: 1, modelNamePrefix: "other"),
        ]
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: changedModel, projects: []))

        let changedMode = [
            Self.entry(date: "2026-06-07", modelCount: 1, hasModeDetails: true),
        ]
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: changedMode, projects: []))

        let reorderedDaily = [
            Self.entry(date: "2026-06-08", modelCount: 1),
            Self.entry(date: "2026-06-07", modelCount: 1),
        ]
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: reorderedDaily, projects: []))
    }

    @Test
    @MainActor
    func `render fingerprint ignores hidden daily accounting fields and source order`() {
        let visibleModel = CostUsageDailyReport.ModelBreakdown(
            modelName: "model-visible",
            costUSD: 0.75,
            totalTokens: 120,
            requestCount: 1,
            standardCostUSD: 0.5,
            priorityCostUSD: 0.25,
            standardTokens: 80,
            priorityTokens: 40)
        let base = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 20,
            cacheCreationTokens: 10,
            totalTokens: 150,
            requestCount: 2,
            costUSD: 1,
            modelsUsed: ["model-visible"],
            modelBreakdowns: [visibleModel])
        let hiddenFieldsChanged = CostUsageDailyReport.Entry(
            date: base.date,
            inputTokens: 999,
            outputTokens: 888,
            cacheReadTokens: 777,
            cacheCreationTokens: 666,
            totalTokens: base.totalTokens,
            requestCount: base.requestCount,
            costUSD: base.costUSD,
            modelsUsed: ["unused-model-name"],
            modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                modelName: visibleModel.modelName,
                costUSD: visibleModel.costUSD,
                totalTokens: visibleModel.totalTokens,
                requestCount: 999,
                standardCostUSD: visibleModel.standardCostUSD,
                priorityCostUSD: visibleModel.priorityCostUSD,
                standardTokens: visibleModel.standardTokens,
                priorityTokens: visibleModel.priorityTokens)])

        #expect(Self.fingerprint(daily: [base]) == Self.fingerprint(daily: [hiddenFieldsChanged]))

        let secondDay = Self.entry(date: "2026-06-08", modelCount: 1)
        #expect(
            Self.fingerprint(daily: [base, secondDay])
                == Self.fingerprint(daily: [secondDay, base]))

        let hiddenModeTokens = CostUsageDailyReport.ModelBreakdown(
            modelName: visibleModel.modelName,
            costUSD: visibleModel.costUSD,
            totalTokens: visibleModel.totalTokens,
            standardTokens: 1,
            priorityTokens: 2)
        let changedHiddenModeTokens = CostUsageDailyReport.ModelBreakdown(
            modelName: visibleModel.modelName,
            costUSD: visibleModel.costUSD,
            totalTokens: visibleModel.totalTokens,
            standardTokens: 999,
            priorityTokens: 888)
        #expect(
            Self.fingerprint(daily: [Self.entry(modelBreakdowns: [hiddenModeTokens])])
                == Self.fingerprint(daily: [Self.entry(modelBreakdowns: [changedHiddenModeTokens])]))
    }

    @Test
    @MainActor
    func `render fingerprint excludes invalid daily rows that the chart drops`() {
        let invalidRows = [
            Self.dailyEntry(date: "2026-06-07", costUSD: nil),
            Self.dailyEntry(date: "2026-06-08", costUSD: -1),
            Self.dailyEntry(date: "not-a-date", costUSD: 1),
        ]
        let differentInvalidRows = [
            Self.dailyEntry(date: "2026-06-09", costUSD: nil),
            Self.dailyEntry(date: "2026-06-10", costUSD: -99),
            Self.dailyEntry(date: "still-not-a-date", costUSD: 99),
        ]
        let empty = Self.fingerprint(daily: [])

        #expect(Self.fingerprint(daily: invalidRows) == Self.fingerprint(daily: differentInvalidRows))
        #expect(Self.fingerprint(daily: invalidRows) != empty)
        #expect(Self.fingerprint(daily: [Self.dailyEntry(date: "2026-06-07", costUSD: 1)]) != empty)
    }

    @Test
    @MainActor
    func `render fingerprint tracks every visible model breakdown field`() {
        let base = CostUsageDailyReport.ModelBreakdown(
            modelName: "model-visible",
            costUSD: 1,
            totalTokens: 100,
            standardCostUSD: 0.75,
            priorityCostUSD: 0.25,
            standardTokens: 75,
            priorityTokens: 25)
        let variants = [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "model-renamed",
                costUSD: base.costUSD,
                totalTokens: base.totalTokens,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: base.standardTokens,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: 2,
                totalTokens: base.totalTokens,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: base.standardTokens,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: base.costUSD,
                totalTokens: 200,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: base.standardTokens,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: base.costUSD,
                totalTokens: base.totalTokens,
                standardCostUSD: 0.5,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: base.standardTokens,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: base.costUSD,
                totalTokens: base.totalTokens,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: 0.5,
                standardTokens: base.standardTokens,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: base.costUSD,
                totalTokens: base.totalTokens,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: 50,
                priorityTokens: base.priorityTokens),
            CostUsageDailyReport.ModelBreakdown(
                modelName: base.modelName,
                costUSD: base.costUSD,
                totalTokens: base.totalTokens,
                standardCostUSD: base.standardCostUSD,
                priorityCostUSD: base.priorityCostUSD,
                standardTokens: base.standardTokens,
                priorityTokens: 50),
        ]
        let baseFingerprint = Self.fingerprint(daily: [Self.entry(modelBreakdowns: [base])])

        for variant in variants {
            #expect(baseFingerprint != Self.fingerprint(daily: [Self.entry(modelBreakdowns: [variant])]))
        }
    }

    @Test
    @MainActor
    func `render fingerprint excludes projects hidden for non-codex providers`() {
        let first = Self.fingerprint(
            projects: [Self.makeProject(index: 0, sourceCount: 2)],
            provider: .claude)
        let changed = Self.fingerprint(
            projects: [Self.makeProject(index: 0, sourceCount: 2, totalCostUSD: 99)],
            provider: .claude)

        #expect(first.projects.isEmpty)
        #expect(first == changed)
    }

    @Test
    @MainActor
    func `render fingerprint tracks visible project and source fields only`() {
        let daily = [Self.entry(date: "2026-06-07", modelCount: 1)]
        let projects = Self.makeProjects(count: 6, sourcesPerProject: 3)
        let base = Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: projects)

        var sixthProjectNestedDaily = projects
        sixthProjectNestedDaily[5] = Self.makeProject(
            index: 5,
            sourceCount: 3,
            nestedDailyCost: 99.0)
        #expect(base == Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: sixthProjectNestedDaily))

        var topProjectNestedDaily = projects
        topProjectNestedDaily[0] = Self.makeProject(
            index: 0,
            sourceCount: 3,
            nestedDailyCost: 99.0)
        #expect(base == Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: topProjectNestedDaily))

        var renamedTopProject = projects
        renamedTopProject[0] = Self.makeProject(index: 0, sourceCount: 3, nameSuffix: "-renamed")
        #expect(base != Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: renamedTopProject))

        var changedTopProjectPath = projects
        changedTopProjectPath[0] = Self.makeProject(index: 0, sourceCount: 3, pathSuffix: "-renamed")
        #expect(base != Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: changedTopProjectPath))

        var changedTopProjectTotals = projects
        changedTopProjectTotals[0] = Self.makeProject(index: 0, sourceCount: 3, totalCostUSD: 42.0, totalTokens: 9999)
        #expect(base != Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: changedTopProjectTotals))

        let reorderedProjects = Array(projects.reversed())
        #expect(base != Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: reorderedProjects))

        var promotedHiddenProject = projects
        let promoted = Self.makeProject(
            index: 5,
            sourceCount: 3,
            totalCostUSD: 1000.0)
        promotedHiddenProject.remove(at: 5)
        promotedHiddenProject.insert(promoted, at: 0)
        #expect(base != Self.fingerprint(totalCostUSD: 6.0, daily: daily, projects: promotedHiddenProject))
    }

    @Test
    @MainActor
    func `render fingerprint tracks source visibility and overflow count`() {
        let daily = [Self.entry(date: "2026-06-07", modelCount: 1)]
        let twoSources = [
            Self.makeProject(index: 0, sourceCount: 2),
        ]
        let threeSources = [
            Self.makeProject(index: 0, sourceCount: 3),
        ]
        let base = Self.fingerprint(dailyCost: 1.0, daily: daily, projects: twoSources)

        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: daily, projects: threeSources))

        var thirdSourceRenamed = threeSources
        thirdSourceRenamed[0] = Self.makeProject(index: 0, sourceCount: 3, renameThirdSource: true)
        #expect(Self.fingerprint(dailyCost: 1.0, daily: daily, projects: threeSources)
            == Self.fingerprint(dailyCost: 1.0, daily: daily, projects: thirdSourceRenamed))

        var firstSourceRenamed = twoSources
        firstSourceRenamed[0] = Self.makeProject(index: 0, sourceCount: 2, renameFirstSource: true)
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: daily, projects: firstSourceRenamed))

        var firstSourceTotals = twoSources
        firstSourceTotals[0] = Self.makeProject(
            index: 0,
            sourceCount: 2,
            firstSourceCostUSD: 9.99,
            firstSourceTokens: 8888)
        #expect(base != Self.fingerprint(dailyCost: 1.0, daily: daily, projects: firstSourceTotals))

        let hiddenSingleSource = [
            Self.project(path: "/tmp/main", sourcePath: "/tmp/main"),
        ]
        let visibleSingleSource = [
            Self.project(path: "/tmp/main", sourcePath: "/tmp/worktree"),
        ]
        #expect(
            Self.fingerprint(dailyCost: 1.0, daily: daily, projects: hiddenSingleSource)
                != Self.fingerprint(dailyCost: 1.0, daily: daily, projects: visibleSingleSource))
    }

    private static func project(path: String, sourcePath: String) -> CostUsageProjectBreakdown {
        CostUsageProjectBreakdown(
            name: "Project",
            path: path,
            totalTokens: 10,
            totalCostUSD: 0.1,
            daily: [],
            modelBreakdowns: nil,
            sources: [
                CostUsageProjectSourceBreakdown(
                    name: "Source",
                    path: sourcePath,
                    totalTokens: 10,
                    totalCostUSD: 0.1,
                    daily: [],
                    modelBreakdowns: nil),
            ])
    }

    @MainActor
    private static func renderedHeight(daily: [CostUsageDailyReport.Entry]) -> CGFloat {
        let hosting = MenuHostingView(rootView: CostHistoryChartMenuView(
            provider: .codex,
            daily: daily,
            totalCostUSD: nil,
            width: 320))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        hosting.layoutSubtreeIfNeeded()
        return ceil(hosting.fittingSize.height)
    }

    private static func entry(
        date: String,
        modelCount: Int,
        hasModeDetails: Bool = false,
        modelNamePrefix: String = "model") -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            costUSD: 1,
            modelsUsed: modelCount > 0 ? (0..<modelCount).map { "\(modelNamePrefix)-\($0)" } : nil,
            modelBreakdowns: modelCount > 0
                ? (0..<modelCount).map {
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "\(modelNamePrefix)-\($0)",
                        costUSD: Double($0 + 1),
                        totalTokens: ($0 + 1) * 100,
                        standardCostUSD: hasModeDetails ? Double($0 + 1) * 0.75 : nil)
                }
                : nil)
    }

    private static func entry(
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            costUSD: 1,
            modelsUsed: modelBreakdowns.map(\.modelName),
            modelBreakdowns: modelBreakdowns)
    }

    private static func dailyEntry(date: String, costUSD: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            costUSD: costUSD,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func makeSnapshot(
        dailyCost: Double = 1.0,
        projectCount: Int = 0,
        totalCostUSD: Double? = nil,
        currencyCode: String = "USD",
        historyDays: Int = 30,
        historyLabel: String? = nil,
        daily: [CostUsageDailyReport.Entry]? = nil,
        projects: [CostUsageProjectBreakdown]? = nil,
        sessions: [CostUsageSessionBreakdown] = []) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: totalCostUSD ?? dailyCost,
            currencyCode: currencyCode,
            historyDays: historyDays,
            historyLabel: historyLabel,
            daily: daily ?? [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: dailyCost,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            projects: projects ?? self.makeProjects(count: projectCount, sourcesPerProject: 1),
            sessions: sessions,
            updatedAt: Date())
    }

    private static func fingerprint(
        dailyCost: Double = 1.0,
        totalCostUSD: Double? = nil,
        currencyCode: String = "USD",
        historyDays: Int = 30,
        historyLabel: String? = nil,
        daily: [CostUsageDailyReport.Entry]? = nil,
        projects: [CostUsageProjectBreakdown]? = nil,
        sessions: [CostUsageSessionBreakdown] = [],
        provider: UsageProvider = .codex) -> CostHistoryChartMenuView.RenderFingerprint
    {
        CostHistoryChartMenuView.renderFingerprint(from: self.makeSnapshot(
            dailyCost: dailyCost,
            totalCostUSD: totalCostUSD,
            currencyCode: currencyCode,
            historyDays: historyDays,
            historyLabel: historyLabel,
            daily: daily,
            projects: projects,
            sessions: sessions), provider: provider)
    }

    private static func makeProjects(count: Int, sourcesPerProject: Int) -> [CostUsageProjectBreakdown] {
        (0..<count).map { Self.makeProject(index: $0, sourceCount: sourcesPerProject) }
    }

    private static func makeProject(
        index: Int,
        sourceCount: Int,
        totalCostUSD: Double = 1.0,
        totalTokens: Int? = nil,
        nestedDailyCost: Double = 0.01,
        nameSuffix: String = "",
        pathSuffix: String = "",
        renameThirdSource: Bool = false,
        renameFirstSource: Bool = false,
        firstSourceCostUSD: Double? = nil,
        firstSourceTokens: Int? = nil) -> CostUsageProjectBreakdown
    {
        let nestedDaily = [
            CostUsageDailyReport.Entry(
                date: "2025-12-23",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 10,
                costUSD: nestedDailyCost,
                modelsUsed: ["nested"],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "nested-model",
                        costUSD: nestedDailyCost,
                        totalTokens: 10),
                ]),
        ]
        let sources = (0..<sourceCount).map { sourceIndex in
            CostUsageProjectSourceBreakdown(
                name: {
                    if renameThirdSource, sourceIndex == 2 {
                        return "Renamed Source"
                    }
                    if renameFirstSource, sourceIndex == 0 {
                        return "Renamed Source"
                    }
                    return "Source-\(sourceIndex)"
                }(),
                path: "/tmp/project-\(index)\(pathSuffix)/source-\(sourceIndex)",
                totalTokens: sourceIndex == 0 ? (firstSourceTokens ?? 10 + sourceIndex) : 10 + sourceIndex,
                totalCostUSD: sourceIndex == 0
                    ? (firstSourceCostUSD ?? totalCostUSD / Double(sourceCount))
                    : totalCostUSD / Double(sourceCount),
                daily: nestedDaily,
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "source-model",
                        costUSD: nestedDailyCost,
                        totalTokens: 10),
                ])
        }
        return CostUsageProjectBreakdown(
            name: "Project-\(index)\(nameSuffix)",
            path: "/tmp/project-\(index)\(pathSuffix)",
            totalTokens: totalTokens ?? 100 + index,
            totalCostUSD: totalCostUSD + Double(index),
            daily: nestedDaily,
            modelBreakdowns: [
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "project-model",
                    costUSD: nestedDailyCost,
                    totalTokens: 10),
            ],
            sources: sources)
    }
}

extension CostHistoryChartMenuViewTests {
    @Test
    func `session labels distinguish concurrent uuid v7 identifiers`() {
        let first = CostHistoryChartMenuView.shortSessionID("019f6d91-970b-7e13-b08e-000000000001")
        let second = CostHistoryChartMenuView.shortSessionID("019f6d91-970b-7e13-b08e-000000000002")

        #expect(first == "019f...00000001")
        #expect(second == "019f...00000002")
        #expect(first != second)
    }

    @Test
    @MainActor
    func `render fingerprint tracks displayed session token components`() {
        func session(input: Int?, cached: Int?, output: Int?) -> CostUsageSessionBreakdown {
            CostUsageSessionBreakdown(
                sessionID: "session-1",
                lastActivity: Date(timeIntervalSince1970: 100),
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                totalTokens: 110,
                requestCount: 1,
                costUSD: 0.01,
                modelBreakdowns: [])
        }

        let base = Self.fingerprint(sessions: [session(input: 100, cached: 20, output: 10)])
        #expect(base != Self.fingerprint(sessions: [session(input: 90, cached: 20, output: 10)]))
        #expect(base != Self.fingerprint(sessions: [session(input: 100, cached: 10, output: 10)]))
        #expect(base != Self.fingerprint(sessions: [session(input: 100, cached: 20, output: 20)]))
    }
}
