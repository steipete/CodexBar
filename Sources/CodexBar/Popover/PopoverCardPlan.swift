import CodexBarCore

/// popover 内容区的卡片渲染计划：由 StatusItemController 构造（复用 NSMenu 同源数据/分流逻辑），
/// PopoverRootView 纯渲染消费。
struct PopoverCardPlan {
    struct Card: Identifiable {
        let id: String // 稳定 id：账户 id / scope id / "single"
        let model: UsageMenuCardView.Model
        let workspaceHeader: String? // Codex workspace 分组 header（组内首卡携带）
    }

    var cards: [Card] = []
    var storageText: String?
    var showBuyCredits = false
    var emptyText: String? // 无任何卡片时的占位文案
}
