import CodexBarCore

/// popover 内容区的卡片渲染计划：由 StatusItemController 构造（复用 NSMenu 同源数据/分流逻辑），
/// PopoverRootView 纯渲染消费。
struct PopoverCardPlan {
    struct Card: Identifiable {
        let id: String // 稳定 id：账户 id / scope id / "single"
        let model: UsageMenuCardView.Model
        let workspaceHeader: String? // Codex workspace 分组 header（组内首卡携带）
    }

    /// 拆段渲染计划（对齐 NSMenu addMenuCardSections；仅 OpenAI web/API usage 场景）。
    /// 非 nil 时 PopoverRootView 优先走拆段路径，不渲染整卡（cards 字段此时通常含 1 张卡用于占位，
    /// 实际不直接渲染）。
    struct SectionedCard {
        let model: UsageMenuCardView.Model
        // ── 段存在性标志 ──
        let hasUsageBlock: Bool // model.hasUsageContent
        let hasCredits: Bool // model.creditsText != nil
        let hasExtraUsage: Bool // model.providerCost != nil
        let hasCost: Bool // model.tokenUsage != nil
        let hasStorage: Bool // storageFootprintText(for:) != nil
        let storageText: String? // 同上，nil 时不渲染 storage 段
        // ── 段 chevron 图表（对齐 NSMenu 各段 submenu 条件）──
        let usageChart: PopoverChartKind? // hasUsageBreakdown→.usageBreakdown / openai→.costHistory / zai→.zaiDetails
        let storageChart: PopoverChartKind? // storage components 非空→.storageBreakdown(provider)
        let creditsChart: PopoverChartKind? // hasCreditsHistory→.creditsHistory
        let showBuyCredits: Bool // webItems.canShowBuyCredits（Credits 段后跟 Buy Credits 行）
        let extraUsageChart: PopoverChartKind? // OpenAI API usage submenu → .costHistory(provider)
        let costChart: PopoverChartKind? // hasCostHistory→.costHistory(provider)
    }

    /// 非 nil 时优先于 cards 路径走拆段渲染（PopoverRootView.card(for:) 中判定）。
    var sectioned: SectionedCard?

    var cards: [Card] = []
    var storageText: String?
    var showBuyCredits = false
    var emptyText: String? // 无任何卡片时的占位文案
}
