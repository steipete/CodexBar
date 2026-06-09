import SwiftUI

/// 持久面板根视图。阶段 0 占位；阶段 1 接入切换器 + 单卡片。
struct PopoverRootView: View {
    @Bindable var viewModel: MenuViewModel
    var body: some View {
        Color.clear.frame(width: 310, height: 1)
    }
}
