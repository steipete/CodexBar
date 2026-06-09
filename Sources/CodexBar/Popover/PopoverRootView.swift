import SwiftUI
import CodexBarCore

/// 持久面板根视图。阶段 1：provider 切换器 + 当前 provider 用量卡片。
/// 整个 popover 生命周期只构造一次；切 provider 通过 viewModel.select(_:) 增量更新，不重建视图。
struct PopoverRootView: View {
    @Bindable var viewModel: MenuViewModel
    /// 注入 UsageStore 引用，用于在 body 中建立 @Observable 观察链：
    /// store 数据变化时 SwiftUI 自动重渲而无需外部 bump。
    let store: UsageStore
    /// 由 StatusItemController 注入的卡片 model 构造闭包（self.menuCardModel(for:)）。
    /// 持有 weak self 引用，避免强引用环。
    let makeCardModel: (UsageProvider) -> UsageMenuCardView.Model?

    private static let menuWidth: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.providers.count > 1 {
                switcher
                Divider()
            }
            content
        }
        .frame(width: Self.menuWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 最小 SwiftUI 切换器（Phase 1：纯文字按钮；图标/配额指示留 Phase 2）

    private var switcher: some View {
        HStack(spacing: 4) {
            ForEach(viewModel.providers, id: \.self) { provider in
                Button {
                    viewModel.select(.provider(provider))
                } label: {
                    Text(provider.rawValue)
                        .font(.caption)
                        .fontWeight(isSelected(provider) ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSelected(provider) ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8)
    }

    // MARK: - 内容区

    @ViewBuilder private var content: some View {
        switch viewModel.selection {
        case .overview:
            // Phase 1 最小：overview 展示首个 provider 卡片；完整 Overview 留 Phase 2
            card(for: viewModel.providers.first ?? .codex)
        case let .provider(p):
            card(for: p)
        }
    }

    /// 关键：在 body 中同步读取 store（makeCardModel 内部读 store.* 属性），
    /// 以建立 @Observable 观察链——store 数据变化时 SwiftUI 自动重渲。
    @ViewBuilder private func card(for provider: UsageProvider) -> some View {
        if let model = makeCardModel(provider) {
            UsageMenuCardView(model: model, width: Self.menuWidth)
        } else {
            // store.snapshot 读取触发 @Observable 追踪，数据到达时自动更新
            let _ = store.snapshot(for: provider)
            Text("Loading…")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    // MARK: - 辅助

    private func isSelected(_ provider: UsageProvider) -> Bool {
        if case let .provider(p) = viewModel.selection { return p == provider }
        return false
    }
}
