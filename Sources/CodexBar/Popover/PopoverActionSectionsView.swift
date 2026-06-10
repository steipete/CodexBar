import SwiftUI

// MARK: - 悬停高亮 ViewModifier

/// 菜单行悬停高亮：复刻 NSMenu 行高亮观感（accent 背景 + 反白文字）。
/// 应用到所有可点击菜单行（action、图表入口、Overview 行等）。
struct MenuRowHoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(self.isHovered ? Color.accentColor : Color.clear)
            .foregroundStyle(self.isHovered ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { self.isHovered = $0 }
    }
}

extension View {
    /// 应用 NSMenu 风格行悬停高亮（accent 背景 + 反白文字）。
    func menuRowHoverHighlight() -> some View {
        modifier(MenuRowHoverHighlight())
    }
}

// MARK: - PopoverActionSectionsView

/// popover 底部动作区：把 MenuDescriptor.Section 列表渲染为 SwiftUI 视图。
/// sections 来自 MenuDescriptor.build(...)，与 NSMenu 路径共用同一数据源。
struct PopoverActionSectionsView: View {
    let sections: [MenuDescriptor.Section]
    let onAction: (MenuDescriptor.MenuAction) -> Void
    /// 返回 action 对应的禁用 subtitle（nil = 可用；非 nil = 禁用并显示 subtitle 小字）。
    /// 对齐 NSMenu addActionableSections switchAccount/addCodexAccount disabled 逻辑。
    var actionSubtitle: ((MenuDescriptor.MenuAction) -> String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 与 NSMenu addActionableSections 过滤逻辑完全对齐：
            // 只保留含 action 或 submenu 的 section，纯文本 section（usage/account 信息行）不渲染。
            let actionable = self.sections.filter { section in
                section.entries.contains { entry in
                    if case .action = entry { return true }
                    if case .submenu = entry { return true }
                    return false
                }
            }
            ForEach(Array(actionable.enumerated()), id: \.offset) { idx, section in
                if idx > 0 {
                    Divider()
                }
                self.sectionView(section)
            }
        }
    }

    // MARK: - Section

    private func sectionView(_ section: MenuDescriptor.Section) -> some View {
        ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
            self.entryView(entry)
        }
    }

    // MARK: - Entry

    @ViewBuilder
    private func entryView(_ entry: MenuDescriptor.Entry) -> some View {
        switch entry {
        case let .text(text, style):
            self.textView(text, style: style)
        case let .action(title, action):
            self.actionButton(title: title, action: action)
        case let .submenu(title, systemImage, items):
            self.submenuView(title: title, systemImage: systemImage, items: items)
        case .divider:
            Divider()
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func textView(_ text: String, style: MenuDescriptor.TextStyle) -> some View {
        switch style {
        case .headline:
            Text(text)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        case .primary:
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        case .secondary:
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private func actionButton(title: String, action: MenuDescriptor.MenuAction) -> some View {
        let subtitle = self.actionSubtitle?(action)
        let isDisabled = subtitle != nil
        ActionRowButton(
            title: title,
            action: action,
            subtitle: subtitle,
            isDisabled: isDisabled,
            onAction: self.onAction)
    }

    // MARK: - 快捷键 a11y hint 映射

    /// 返回动作对应的无障碍 hint（供 VoiceOver 朗读快捷键）；nil 表示无快捷键。
    static func shortcutHint(for action: MenuDescriptor.MenuAction) -> String? {
        switch action {
        case .refresh: "Command R"
        case .settings: "Command Comma"
        case .quit: "Command Q"
        default: nil
        }
    }

    // MARK: - Submenu

    @ViewBuilder
    private func submenuView(
        title: String,
        systemImage: String?,
        items: [MenuDescriptor.SubmenuItem]) -> some View
    {
        let menuContent = {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let action = item.action {
                    Button {
                        self.onAction(action)
                    } label: {
                        Text(item.isChecked ? "✓ \(item.title)" : item.title)
                    }
                    .disabled(!item.isEnabled)
                } else {
                    Text(item.title)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let systemImage {
            Menu {
                menuContent()
            } label: {
                Label(title, systemImage: systemImage)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        } else {
            Menu {
                menuContent()
            } label: {
                Text(title)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
    }

    // MARK: - 快捷键标签（静态，可测试）

    /// 返回动作对应的快捷键显示字符串；nil 表示无快捷键。
    static func shortcutLabel(for action: MenuDescriptor.MenuAction) -> String? {
        switch action {
        case .refresh: "⌘R"
        case .settings: "⌘,"
        case .quit: "⌘Q"
        default: nil
        }
    }
}

// MARK: - ActionRowButton（独立视图，持有 isHovered @State）

/// 单个动作行，持有自己的 hover 状态。
/// 抽出为独立 View 以便在 @ViewBuilder 外持有 @State private var isHovered。
private struct ActionRowButton: View {
    let title: String
    let action: MenuDescriptor.MenuAction
    let subtitle: String?
    let isDisabled: Bool
    let onAction: (MenuDescriptor.MenuAction) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            self.onAction(self.action)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.title)
                    if let subtitle = self.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(
                                self.isHovered ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let label = PopoverActionSectionsView.shortcutLabel(for: self.action) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(
                            self.isHovered ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled)
        // hover 高亮仅在可用时生效
        .background(
            (self.isHovered && !self.isDisabled) ? Color.accentColor : Color.clear)
        .foregroundStyle(
            (self.isHovered && !self.isDisabled) ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 5)
        .onHover { hovering in
            if !self.isDisabled { self.isHovered = hovering }
        }
        // 禁用 popover 内的键盘 focus 框（macOS 14+）
        .focusEffectDisabled()
        // 无障碍：Button 自带 button trait；为有快捷键的动作加 hint
        .accessibilityHint(
            PopoverActionSectionsView.shortcutHint(for: self.action) ?? "")
    }
}
