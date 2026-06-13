import CodexBarCore
import CoreGraphics
import Observation

/// 面板内容的单一可观察状态源。替代旧架构中以 ObjectIdentifier(NSMenu) 为 key 的
/// openMenus / menuVersions / highlightedMenuItems 等字典追踪。
@MainActor
@Observable
final class MenuViewModel {
    /// 切换器选择：Overview 或具体 provider。复用既有 ProviderSwitcherSelection 语义。
    var selection: ProviderSwitcherSelection = .overview
    /// 当前可显示的 provider 列表（合并模式切换器用）。
    var providers: [UsageProvider] = []
    /// Popover height cap derived from the status item's current screen.
    var maximumPopoverHeight: CGFloat = 720
    /// 切换器是否含 Overview tab（由 controller 在 attach/打开时刷新）。
    var includesOverview: Bool = false
    /// 内容版本号，选择/数据变化时自增，供 SwiftUI 视图 diff 参考（替代 menuContentVersion）。
    private(set) var contentVersion: Int = 0
    /// popover 是否可见（替代 openMenus 字典；后续图标动画据此冻结）。
    private(set) var isVisible: Bool = false
    /// 当前高亮项 id（集中式高亮，替代 highlightedMenuItems 字典）。
    var highlightedItemID: String?
    /// selection 变化时回调（controller 注入以持久化）。同值不触发。
    var onSelectionChanged: ((ProviderSwitcherSelection) -> Void)?

    init() {}

    /// 单 provider 模式便利工厂：providers=[provider]、includesOverview=false、selection=.provider(provider)、不设
    /// onSelectionChanged。
    /// 供非合并模式 per-provider popover 和测试使用。
    static func singleProvider(_ provider: UsageProvider) -> MenuViewModel {
        let vm = MenuViewModel()
        vm.providers = [provider]
        vm.includesOverview = false
        // 直接赋值而非调用 select()，避免触发 onSelectionChanged（此时尚未注册，且单 provider 不需持久化）
        vm.selection = .provider(provider)
        return vm
    }

    func select(_ newSelection: ProviderSwitcherSelection) {
        guard newSelection != self.selection else { return }
        self.selection = newSelection
        self.contentVersion &+= 1
        self.onSelectionChanged?(newSelection)
    }

    func bumpContentVersion() {
        self.contentVersion &+= 1
    }

    func setVisible(_ visible: Bool) {
        self.isVisible = visible
    }

    // MARK: - 导航助手（Task 1.4）

    /// 循环切换的停靠点：includesOverview 为 true 时含 Overview，否则仅 providers。
    private var navigationStops: [ProviderSwitcherSelection] {
        let providerStops = self.providers.map { ProviderSwitcherSelection.provider($0) }
        return self.includesOverview ? [.overview] + providerStops : providerStops
    }

    func selectNext() {
        self.cycleSelection(by: 1)
    }

    func selectPrevious() {
        self.cycleSelection(by: -1)
    }

    private func cycleSelection(by delta: Int) {
        let stops = self.navigationStops
        guard !stops.isEmpty else { return }
        let currentIndex = stops.firstIndex(of: self.selection) ?? 0
        let nextIndex = ((currentIndex + delta) % stops.count + stops.count) % stops.count
        self.select(stops[nextIndex])
    }

    func selectProvider(atIndex index: Int) {
        guard self.providers.indices.contains(index) else { return }
        self.select(.provider(self.providers[index]))
    }
}
