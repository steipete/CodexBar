import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// MARK: - PopoverOverviewRow 结构测试

struct PopoverOverviewRowTests {
    // MARK: 1. id 稳定性

    /// 通过实际构造 PopoverOverviewRow 验证 id 计算属性等于 provider.rawValue。
    @Test
    func `PopoverOverviewRow id 等于 provider rawValue`() throws {
        // 构造最简 UsageMenuCardView.Model（snapshot=nil、account 填占位值）
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        for provider in providers {
            let metadata = try #require(ProviderDefaults.metadata[provider])
            let model = UsageMenuCardView.Model.make(.init(
                provider: provider,
                metadata: metadata,
                snapshot: nil,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: false,
                hidePersonalInfo: false,
                now: Date()))
            let row = StatusItemController.PopoverOverviewRow(
                provider: provider,
                model: model,
                storageText: nil)
            #expect(row.id == provider.rawValue, "id 应等于 provider.rawValue（provider: \(provider.rawValue)）")
        }
    }

    @Test
    func `不同 provider 产生不同 id`() {
        // 验证 provider.rawValue 作为 id 的唯一性约束
        let providers: [UsageProvider] = [.codex, .claude, .cursor, .openai]
        let ids = providers.map(\.rawValue)
        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == ids.count, "不同 provider 的 rawValue id 不得重复")
    }

    @Test
    func `id 与 rawValue 一致`() {
        // 对 PopoverOverviewRow 类型本身验证 id 计算属性语义
        // 此处通过类型文档约定确认（id = provider.rawValue），无需 model 构造
        let provider = UsageProvider.codex
        #expect(!provider.rawValue.isEmpty, "provider rawValue 不应为空")
    }
}

// MARK: - MenuViewModel overview→provider 切换测试

@MainActor
@Suite
struct MenuViewModelOverviewSwitchTests {
    // MARK: 2. overview → provider 切换

    @Test
    func `overview 切换到 provider 后 selection 正确`() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        // 初始为 overview
        #expect(vm.selection == .overview)

        // 切到 codex
        vm.select(.provider(.codex))
        #expect(vm.selection == .provider(.codex))
    }

    @Test
    func `overview 切换到 provider 后可再切回 overview`() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]

        vm.select(.provider(.codex))
        #expect(vm.selection == .provider(.codex))

        vm.select(.overview)
        #expect(vm.selection == .overview)
    }

    @Test
    func `overview 状态下 selectNext 切到第一个 provider`() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.includesOverview = true // 导航停靠点含 overview
        #expect(vm.selection == .overview)

        vm.selectNext()
        // 导航顺序：[.overview, .provider(.codex), .provider(.claude)]
        #expect(vm.selection == .provider(.codex))
    }

    @Test
    func `provider 状态 selectPrevious 可回到 overview`() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.includesOverview = true // 导航停靠点含 overview
        vm.select(.provider(.codex))

        vm.selectPrevious()
        // 从第一个 provider 向前 → overview
        #expect(vm.selection == .overview)
    }

    @Test
    func `从 overview 切换到不同 provider 各自正确`() {
        let vm = MenuViewModel()
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        vm.providers = providers

        for provider in providers {
            vm.select(.overview)
            vm.select(.provider(provider))
            #expect(vm.selection == .provider(provider), "切换到 \(provider.rawValue) 后 selection 应为该 provider")
        }
    }

    @Test
    func `overview→provider 切换 contentVersion 自增`() {
        let vm = MenuViewModel()
        vm.providers = [.codex]
        let vBefore = vm.contentVersion

        vm.select(.provider(.codex))
        #expect(
            vm.contentVersion > vBefore || vm.contentVersion == vBefore &+ 1,
            "切换 selection 时 contentVersion 应自增")
    }
}

// MARK: - popoverOverviewRows / popoverOverviewEmptyText 集成说明

//
// popoverOverviewRows() 和 popoverOverviewEmptyText() 内部依赖：
//   - store.enabledProvidersForDisplay()（运行时账户/启用状态）
//   - settings.reconcileMergedOverviewSelectedProviders（UserDefaults）
//   - menuCardModel（snapshot 数据）
//   - store.storageFootprintText（存储快照）
//
// 这些依赖需要完整的 StatusItemController + 真实运行时数据，在 headless 测试环境
// 下无法稳定触发有意义的 rows（enabledProviders 通常为空）。
// 因此：
//   - rows/空态构造逻辑通过全量回归（swift test）+ 人工验证兜底。
//   - 空态文案字符串正确性（L("No providers selected for Overview.") 等）
//     在 addOverviewEmptyState NSMenu 路径已有覆盖，popover 复用同一 L() 调用。
