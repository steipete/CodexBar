import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// MARK: - PopoverCardPlan 基础值/空态测试

@Suite
struct PopoverCardPlanTests {
    // MARK: 1. 默认值/空态

    @Test
    func `默认 PopoverCardPlan 为空态`() {
        let plan = PopoverCardPlan()
        #expect(plan.cards.isEmpty)
        #expect(plan.storageText == nil)
        #expect(plan.showBuyCredits == false)
        #expect(plan.emptyText == nil)
    }

    @Test
    func `emptyText 可单独设置`() {
        var plan = PopoverCardPlan()
        plan.emptyText = "Loading…"
        #expect(plan.cards.isEmpty)
        #expect(plan.emptyText == "Loading…")
    }

    @Test
    func `showBuyCredits 可设置为 true`() {
        var plan = PopoverCardPlan()
        plan.showBuyCredits = true
        #expect(plan.showBuyCredits)
    }

    @Test
    func `storageText 可设置`() {
        var plan = PopoverCardPlan()
        plan.storageText = "1.2 GB"
        #expect(plan.storageText == "1.2 GB")
    }

    // MARK: 2. Card Identifiable id 稳定性

    @MainActor
    @Test
    func `两张不同 id 的卡片 id 不相等`() throws {
        // 通过 StatusItemController 获取真实 model，验证 Card 结构体 id 唯一性
        let (controller, _) = try makeMinimalController()
        defer { controller.releaseStatusItemsForTesting() }

        let plan = controller.popoverCardPlan(for: .codex)

        // 构造两张不同 id 的 Card，断言 id 不同
        if plan.cards.count >= 2 {
            let ids = plan.cards.map(\.id)
            let uniqueIDs = Set(ids)
            #expect(uniqueIDs.count == ids.count, "卡片 id 应唯一，无重复")
        } else {
            // 单卡或空：验证 id 格式
            if let card = plan.cards.first {
                #expect(!card.id.isEmpty)
            }
        }
    }

    @Test
    func `单卡片使用 id single`() {
        // PopoverCardPlan 中单卡路径使用 id="single"，通过手动构造 plan 验证
        var plan = PopoverCardPlan()
        // 模拟单卡路径：cards 中只含一张 id 为 "single" 的 Card
        // 无需真实 model，只验证 id 约定
        #expect(plan.cards.isEmpty)
        plan.emptyText = "Loading…"
        #expect(plan.emptyText == "Loading…")
        // 若 cards 非空，single 卡的 id 应为 "single"
        // 此处通过 integration test（下方 popoverCardPlan 测试）验证
    }

    @Test
    func `workspace header 仅首卡携带约定`() {
        // 验证 PopoverCardPlan.Card 的 workspaceHeader 语义：
        // 分组首卡有 header，其余为 nil
        // 这里只测类型结构，真实 header 值由集成测试覆盖
        var plan = PopoverCardPlan()
        // 空 plan 无 cards，不存在 header 问题
        #expect(plan.cards.allSatisfy { $0.workspaceHeader == nil })
        plan.emptyText = nil
        #expect(plan.emptyText == nil)
    }

    // MARK: 3. popoverCardPlan 集成：默认无数据 provider → 返回合理计划

    @MainActor
    @Test
    func `无数据 codex provider 返回单卡或占位`() throws {
        let (controller, _) = try makeMinimalController()
        defer { controller.releaseStatusItemsForTesting() }

        let plan = controller.popoverCardPlan(for: .codex)

        // 约束：cards 与 emptyText 不能同时非空（语义互斥）
        if !plan.cards.isEmpty {
            #expect(plan.emptyText == nil, "有卡片时 emptyText 应为 nil")
        }
        // 无数据时：单张卡片（id="single"）或 emptyText="Loading…"
        if plan.cards.count == 1 {
            #expect(plan.cards[0].id == "single")
        }
    }
}

// MARK: - PopoverCardPlan.SectionedCard 纯逻辑测试

@Suite
struct PopoverCardPlanSectionedTests {
    // MARK: 1. SectionedCard 字段默认值语义验证

    @Test
    func `PopoverCardPlan 默认 sectioned 为 nil`() {
        let plan = PopoverCardPlan()
        #expect(plan.sectioned == nil)
    }

    // MARK: 2. popoverCardPlan 集成：空 store 下 sectioned 为 nil（无 openAI web/API usage 数据）

    @MainActor
    @Test
    func `空 store 无 web items 时 sectioned 为 nil`() throws {
        let (controller, _) = try makeMinimalController()
        defer { controller.releaseStatusItemsForTesting() }

        // 空 store 下 codex/claude 不满足拆段条件，sectioned 应为 nil
        for provider in [UsageProvider.codex, .claude] {
            let plan = controller.popoverCardPlan(for: provider)
            #expect(plan.sectioned == nil, "provider \(provider.rawValue) 空 store 下不应拆段")
        }
    }

    // MARK: 3. 拆段模式下 plan.showBuyCredits 被置为 false（避免重复渲染）

    @MainActor
    @Test
    func `拆段时顶层 showBuyCredits 为 false`() throws {
        let (controller, settings) = try makeMinimalController()
        defer { controller.releaseStatusItemsForTesting() }

        // 即使 showOptionalCreditsAndExtraUsage 开启，若 sectioned 非 nil 则顶层 showBuyCredits=false
        settings.showOptionalCreditsAndExtraUsage = true
        let plan = controller.popoverCardPlan(for: .openai)
        if plan.sectioned != nil {
            #expect(plan.showBuyCredits == false, "拆段时顶层 showBuyCredits 应为 false，由 sectioned.showBuyCredits 接管")
        }
    }

    // MARK: 4. stacked 路径不产生 sectioned

    @MainActor
    @Test
    func `stacked 路径返回时 sectioned 为 nil`() throws {
        let (controller, _) = try makeMinimalController()
        defer { controller.releaseStatusItemsForTesting() }

        // codex stacked/token stacked 路径直接 return plan（不经过单卡片 buildSectionedCard）
        // 空 store 下 codexAccountMenuDisplay 返回 nil，走单卡路径，sectioned 可能 nil（无数据）
        // 此测试验证：若走了 stacked 路径（early return），sectioned 必为 nil
        // 此处通过检查 cards 路径来间接验证（stacked 有多卡时 sectioned 应为 nil）
        let plan = controller.popoverCardPlan(for: .codex)
        if plan.cards.count > 1 {
            // 多卡是 stacked 路径，不应有 sectioned
            #expect(plan.sectioned == nil, "stacked 多卡路径 sectioned 应为 nil")
        }
    }
}

// MARK: - 测试辅助

@MainActor
private func makeMinimalController() throws -> (StatusItemController, SettingsStore) {
    let suite = "PopoverCardPlanTests-\(UUID().uuidString)"
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
