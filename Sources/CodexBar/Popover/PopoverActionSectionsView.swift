import SwiftUI

/// popover 底部动作区：把 MenuDescriptor.Section 列表渲染为 SwiftUI 视图。
/// sections 来自 MenuDescriptor.build(...)，与 NSMenu 路径共用同一数据源。
struct PopoverActionSectionsView: View {
    let sections: [MenuDescriptor.Section]
    let onAction: (MenuDescriptor.MenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let nonEmpty = self.sections.filter { !$0.entries.isEmpty }
            ForEach(Array(nonEmpty.enumerated()), id: \.offset) { idx, section in
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

    private func actionButton(title: String, action: MenuDescriptor.MenuAction) -> some View {
        Button {
            self.onAction(action)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if let label = Self.shortcutLabel(for: action) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
