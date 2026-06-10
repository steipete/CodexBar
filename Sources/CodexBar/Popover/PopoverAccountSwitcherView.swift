import SwiftUI

/// popover 内的账户 segmented 切换器（Codex/Token 通用，纯渲染）。
/// 视觉与 PopoverRootView 的 provider 切换器对齐：plain Button、选中 accentColor.opacity(0.18)
/// 背景圆角 5、caption 字体、选中 semibold。accounts > 3 时用 LazyVGrid 自适应换行。
struct PopoverAccountSwitcherView: View {
    struct Segment: Identifiable, Equatable {
        let id: String
        let title: String
        let isSelected: Bool

        /// 纯函数：从 ids/titles/selectedID 构造 segments，供测试和生产共用。
        static func make(
            ids: [String],
            titles: [String],
            selectedID: String?) -> [Segment]
        {
            zip(ids, titles).map { id, title in
                Segment(id: id, title: title, isSelected: id == selectedID)
            }
        }
    }

    let segments: [Segment]
    let onSelect: (String) -> Void

    var body: some View {
        if self.segments.count > 3 {
            self.gridLayout
        } else {
            self.rowLayout
        }
    }

    // MARK: - 布局变体

    /// <= 3 个账户：单行 HStack，与 provider 切换器样式完全一致。
    private var rowLayout: some View {
        HStack(spacing: 4) {
            ForEach(self.segments) { segment in
                self.button(for: segment)
            }
        }
        .padding(8)
    }

    /// > 3 个账户：自适应 LazyVGrid 多列布局，每列最小宽度 90pt。
    private var gridLayout: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90))],
            alignment: .leading,
            spacing: 4)
        {
            ForEach(self.segments) { segment in
                self.button(for: segment)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(8)
    }

    // MARK: - 单个按钮

    private func button(for segment: Segment) -> some View {
        Button {
            self.onSelect(segment.id)
        } label: {
            Text(segment.title)
                .font(.caption)
                .fontWeight(segment.isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(segment.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
