import Observation
import CodexBarCore

/// 面板内容的单一可观察状态源。替代旧架构中以 ObjectIdentifier(NSMenu) 为 key 的
/// openMenus / menuVersions / highlightedMenuItems 等字典追踪。
@MainActor
@Observable
final class MenuViewModel {
    /// 切换器选择：Overview 或具体 provider。复用既有 ProviderSwitcherSelection 语义。
    var selection: ProviderSwitcherSelection = .overview
    /// 当前可显示的 provider 列表（合并模式切换器用）。
    var providers: [UsageProvider] = []
    /// 内容版本号，选择/数据变化时自增，供 SwiftUI 视图 diff 参考（替代 menuContentVersion）。
    private(set) var contentVersion: Int = 0
    /// popover 是否可见（替代 openMenus 字典；后续图标动画据此冻结）。
    private(set) var isVisible: Bool = false
    /// 当前高亮项 id（集中式高亮，替代 highlightedMenuItems 字典）。
    var highlightedItemID: String?

    init() {}

    func select(_ newSelection: ProviderSwitcherSelection) {
        guard newSelection != self.selection else { return }
        self.selection = newSelection
        self.contentVersion &+= 1
    }

    func bumpContentVersion() { self.contentVersion &+= 1 }

    func setVisible(_ visible: Bool) { self.isVisible = visible }
}
