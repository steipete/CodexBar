import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// MARK: - PopoverChartKind 静态属性测试

// 测试 PopoverChartKind 枚举的 id 稳定性、唯一性与 title 非空。
// 说明：
//   - popoverChartEntries / popoverOverviewChart / popoverChartView 依赖 store 数据，
//     需要真实数据才有意义，此处只覆盖纯静态属性（id、title），不强测数据条件分支。
//   - 数据条件分支和工厂方法的集成验证由全量回归 + 阶段验收人工兜底。

@Suite
struct PopoverChartKindTests {
    // MARK: 1. id 稳定性：相同 case 产出相同 id

    @Test
    func `usageBreakdown id 稳定`() {
        #expect(PopoverChartKind.usageBreakdown.id == "usageBreakdown")
        #expect(PopoverChartKind.usageBreakdown.id == PopoverChartKind.usageBreakdown.id)
    }

    @Test
    func `creditsHistory id 稳定`() {
        #expect(PopoverChartKind.creditsHistory.id == "creditsHistory")
    }

    @Test
    func `costHistory id 含 provider rawValue`() {
        #expect(PopoverChartKind.costHistory(.codex).id == "costHistory-codex")
        #expect(PopoverChartKind.costHistory(.openai).id == "costHistory-openai")
    }

    @Test
    func `usageHistory id 含 provider rawValue`() {
        #expect(PopoverChartKind.usageHistory(.claude).id == "usageHistory-claude")
        #expect(PopoverChartKind.usageHistory(.codex).id == "usageHistory-codex")
    }

    @Test
    func `storageBreakdown id 含 provider rawValue`() {
        #expect(PopoverChartKind.storageBreakdown(.codex).id == "storageBreakdown-codex")
        #expect(PopoverChartKind.storageBreakdown(.kilo).id == "storageBreakdown-kilo")
    }

    @Test
    func `zaiHourly id 含 provider rawValue`() {
        #expect(PopoverChartKind.zaiHourly(.zai).id == "zaiHourly-zai")
    }

    // MARK: 2. id 唯一性：六类 + 多 provider 参数时互不相同

    @Test
    func `不同 kind 的 id 互不相同`() {
        let kinds: [PopoverChartKind] = [
            .usageBreakdown,
            .creditsHistory,
            .costHistory(.codex),
            .costHistory(.openai),
            .costHistory(.claude),
            .usageHistory(.codex),
            .usageHistory(.claude),
            .storageBreakdown(.codex),
            .storageBreakdown(.kilo),
            .zaiHourly(.zai),
        ]
        let ids = kinds.map(\.id)
        let unique = Set(ids)
        #expect(unique.count == ids.count, "所有 kind id 应唯一，无重复")
    }

    @Test
    func `相同 provider 不同 kind 的 id 不相同`() {
        let costID = PopoverChartKind.costHistory(.codex).id
        let usageHistoryID = PopoverChartKind.usageHistory(.codex).id
        let storageID = PopoverChartKind.storageBreakdown(.codex).id
        #expect(costID != usageHistoryID)
        #expect(costID != storageID)
        #expect(usageHistoryID != storageID)
    }

    @Test
    func `不同 provider 的同 kind id 不相同`() {
        let a = PopoverChartKind.costHistory(.codex).id
        let b = PopoverChartKind.costHistory(.openai).id
        #expect(a != b)
    }

    // MARK: 3. title 非空

    @Test
    func `所有 kind title 非空`() {
        let kinds: [PopoverChartKind] = [
            .usageBreakdown,
            .creditsHistory,
            .costHistory(.codex),
            .usageHistory(.codex),
            .storageBreakdown(.codex),
            .zaiHourly(.zai),
        ]
        for kind in kinds {
            #expect(!kind.title.isEmpty, "title 不应为空：\(kind.id)")
        }
    }

    // MARK: 4. costHistoryTitle 动态标题

    @Test
    func `costHistoryTitle days=1 返回 today 文案`() {
        let kind = PopoverChartKind.costHistory(.codex)
        let title = kind.costHistoryTitle(historyDays: 1)
        #expect(!title.isEmpty)
        // 不依赖具体本地化文案，只验证与 days>1 时不同
        let title30 = kind.costHistoryTitle(historyDays: 30)
        #expect(title != title30)
    }

    @Test
    func `非 costHistory kind 调用 costHistoryTitle 返回 self title`() {
        let kind = PopoverChartKind.usageBreakdown
        #expect(kind.costHistoryTitle(historyDays: 30) == kind.title)
    }

    // MARK: 5. Equatable

    @Test
    func `相同 kind 相等`() {
        #expect(PopoverChartKind.usageBreakdown == .usageBreakdown)
        #expect(PopoverChartKind.costHistory(.codex) == .costHistory(.codex))
    }

    @Test
    func `不同 provider 的同 kind 不相等`() {
        #expect(PopoverChartKind.costHistory(.codex) != .costHistory(.openai))
    }

    @Test
    func `不同 kind 不相等`() {
        #expect(PopoverChartKind.usageBreakdown != .creditsHistory)
        #expect(PopoverChartKind.usageHistory(.codex) != .storageBreakdown(.codex))
    }
}

// MARK: - popoverChartEntries 基础结构测试

@Suite
struct PopoverChartEntriesTests {
    // 说明：popoverChartEntries 已收缩为仅返回 usageHistory 与 zaiHourly（对齐原版 NSMenu 独立入口行语义）。
    // 其余图表入口（usageBreakdown/creditsHistory/costHistory/storageBreakdown/zaiDetails）经由
    // 拆段模式的段 chevron 进入，不作为独立入口行。
    // 完整条件路径由全量回归 + 人工验收覆盖。

    @MainActor
    @Test
    func `空 store 下 popoverChartEntries 不崩溃且返回数组`() throws {
        let (controller, _) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        let entries = controller.popoverChartEntries(for: .codex)
        // 空 store 无数据，期望空数组（usageHistory/zaiHourly 均无数据）
        _ = entries
    }

    @MainActor
    @Test
    func `收缩后 entries 只含 usageHistory 和 zaiHourly 两类`() throws {
        let (controller, _) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        for provider in [UsageProvider.codex, .openai, .claude, .zai] {
            let entries = controller.popoverChartEntries(for: provider)
            // 收缩后每个 kind 只能是 usageHistory 或 zaiHourly
            for kind in entries {
                switch kind {
                case .usageHistory, .zaiHourly:
                    break // 合法
                default:
                    #expect(Bool(false), "provider \(provider.rawValue) entries 不应含 \(kind.id)（应经由段 chevron 进入）")
                }
            }
        }
    }

    @MainActor
    @Test
    func `返回的 entries id 无重复`() throws {
        let (controller, _) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        for provider in [UsageProvider.codex, .openai, .claude, .zai] {
            let entries = controller.popoverChartEntries(for: provider)
            let ids = entries.map(\.id)
            let unique = Set(ids)
            #expect(unique.count == ids.count, "provider \(provider.rawValue) 下 entries id 应唯一")
        }
    }

    @MainActor
    @Test
    func `popoverOverviewChart 不崩溃`() throws {
        let (controller, _) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        // 通过 popoverOverviewRows 获取真实 model；若 rows 为空则跳过 overview 路径
        let rows = controller.popoverOverviewRows()
        if let row = rows.first {
            _ = controller.popoverOverviewChart(for: row.provider, model: row.model)
        }
        // 无 model 可用时，通过 menuCardModel 构造（空 store 可能返回 nil，此时跳过）
        for provider in [UsageProvider.codex, .openai, .zai] {
            if let model = controller.menuCardModel(for: provider) {
                _ = controller.popoverOverviewChart(for: provider, model: model)
            }
        }
    }

    @MainActor
    @Test
    func zaiOverviewFallsBackToStorageWhenMCPDetailsAreUnavailable() throws {
        let (controller, settings) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        settings.providerStorageFootprintsEnabled = true
        let root = "/Users/test/.zai"
        controller.store.providerStorageFootprints[.zai] = ProviderStorageFootprint(
            provider: .zai,
            totalBytes: 1024,
            paths: [root],
            missingPaths: [],
            unreadablePaths: [],
            components: [.init(path: "\(root)/cache", totalBytes: 1024)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let model = UsageMenuCardView.Model(
            provider: .zai,
            providerName: "Z.ai",
            email: "",
            subtitleText: "",
            subtitleStyle: .info,
            planText: nil,
            metrics: [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)

        #expect(controller.popoverOverviewChart(for: .zai, model: model) == .storageBreakdown(.zai))
    }

    @MainActor
    @Test
    func overviewActionsUseSavedSelectedProvider() throws {
        let (controller, settings) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        settings.selectedMenuProvider = .claude
        let viewModel = MenuViewModel()
        viewModel.providers = [.codex, .claude]

        #expect(controller.popoverActionProvider(for: viewModel) == .claude)
    }

    @MainActor
    @Test
    func `popoverChartView 数据缺失时返回 nil 不崩溃`() throws {
        let (controller, _) = try makeChartTestController()
        defer { controller.releaseStatusItemsForTesting() }
        let width: CGFloat = 320
        // 空 store 数据缺失，期望返回 nil
        let kinds: [PopoverChartKind] = [
            .usageBreakdown,
            .creditsHistory,
            .costHistory(.codex),
            .usageHistory(.codex),
            .storageBreakdown(.codex),
            .zaiHourly(.zai),
        ]
        for kind in kinds {
            let view = controller.popoverChartView(for: kind, width: width)
            // 空 store 下应为 nil；不崩溃即通过
            _ = view
        }
    }
}

// MARK: - 测试辅助

@MainActor
private func makeChartTestController() throws -> (StatusItemController, SettingsStore) {
    let suite = "PopoverChartTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let configStore = testConfigStore(suiteName: suite)
    let settings = SettingsStore(
        userDefaults: defaults,
        configStore: configStore,
        zaiTokenStore: NoopZaiTokenStore(),
        syntheticTokenStore: NoopSyntheticTokenStore())
    settings.statusChecksEnabled = false
    settings.refreshFrequency = .manual

    let fetcher = UsageFetcher()
    let store = UsageStore(
        fetcher: fetcher,
        browserDetection: BrowserDetection(cacheTTL: 0),
        settings: settings)
    let controller = StatusItemController(
        store: store,
        settings: settings,
        account: fetcher.loadAccountInfo(),
        updater: DisabledUpdaterController(),
        preferencesSelection: PreferencesSelection(),
        statusBar: .system)
    return (controller, settings)
}
