import AppKit
import CodexBarCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let codexBarMenuLayoutItem = UTType(exportedAs: "com.steipete.codexbar.menu-layout-item")
}

struct MenuBarLayoutPosition: Codable, Hashable, Sendable {
    let line: Int
    let index: Int
}

struct MenuBarLayoutDragItem: Codable, Hashable, Transferable, Sendable {
    enum Content: Codable, Hashable, Sendable {
        case token(MenuBarLayoutToken)
        case lineBreak
    }

    let content: Content
    let source: MenuBarLayoutPosition?
    let sourceLayout: MenuBarLayout?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .codexBarMenuLayoutItem)
    }

    static func palette(_ component: MenuBarLayoutToken) -> Self {
        Self(content: .token(component), source: nil, sourceLayout: nil)
    }

    static func placed(
        _ component: MenuBarLayoutToken,
        at source: MenuBarLayoutPosition,
        in layout: MenuBarLayout)
        -> Self
    {
        Self(content: .token(component), source: source, sourceLayout: layout)
    }

    static let lineBreak = Self(content: .lineBreak, source: nil, sourceLayout: nil)
}

enum MenuBarLayoutPaletteTokens {
    static let time: [MenuBarLayoutToken] = [.resetCountdown, .resetAbsolute, .runsOut, .runsOutCompact]
}

enum MenuBarLayoutEditorMutations {
    static func append(_ component: MenuBarLayoutToken, to layout: MenuBarLayout) -> MenuBarLayout {
        var lines = layout.lines
        let line = max(0, lines.count - 1)
        lines[line].append(component)
        return MenuBarLayout(lines: lines)
    }

    static func insert(
        _ item: MenuBarLayoutDragItem,
        at target: MenuBarLayoutPosition,
        in layout: MenuBarLayout)
        -> MenuBarLayout
    {
        if case .lineBreak = item.content {
            return self.addLineBreak(to: layout, at: target.index)
        }

        guard case let .token(token) = item.content else { return layout }
        var lines = layout.lines
        guard !lines.isEmpty else { return MenuBarLayout(lines: [[token]]) }
        var targetLine = min(max(target.line, 0), lines.count - 1)
        var targetIndex = min(max(target.index, 0), lines[targetLine].count)

        if let source = item.source {
            guard item.sourceLayout == layout else { return layout }
            guard lines.indices.contains(source.line),
                  lines[source.line].indices.contains(source.index),
                  lines[source.line][source.index] == token
            else { return layout }
            lines[source.line].remove(at: source.index)
            if source.line == targetLine, source.index < targetIndex {
                targetIndex -= 1
            }
        }

        targetLine = min(max(targetLine, 0), lines.count - 1)
        targetIndex = min(max(targetIndex, 0), lines[targetLine].count)
        lines[targetLine].insert(token, at: targetIndex)
        return MenuBarLayout(lines: lines)
    }

    static func remove(at position: MenuBarLayoutPosition, from layout: MenuBarLayout) -> MenuBarLayout {
        guard layout.lines.indices.contains(position.line),
              layout.lines[position.line].indices.contains(position.index),
              layout.lines.reduce(0, { $0 + $1.count }) > 1
        else { return layout }
        var lines = layout.lines
        lines[position.line].remove(at: position.index)
        guard lines.joined().contains(where: { $0 != .space }) else { return layout }
        return MenuBarLayout(lines: lines)
    }

    static func remove(_ item: MenuBarLayoutDragItem, from layout: MenuBarLayout) -> MenuBarLayout {
        guard let source = item.source,
              item.sourceLayout == layout,
              case let .token(component) = item.content,
              layout.lines.indices.contains(source.line),
              layout.lines[source.line].indices.contains(source.index),
              layout.lines[source.line][source.index] == component
        else { return layout }
        return self.remove(at: source, from: layout)
    }

    static func addLineBreak(to layout: MenuBarLayout, at proposedIndex: Int? = nil) -> MenuBarLayout {
        guard layout.lines.count == 1 else { return layout }
        let line = layout.lines[0]
        guard !line.isEmpty else { return layout }
        if line.count == 1 {
            return MenuBarLayout(lines: [line, []])
        }
        let index = min(max(proposedIndex ?? line.count / 2, 1), line.count - 1)
        return MenuBarLayout(lines: [Array(line[..<index]), Array(line[index...])])
    }

    static func removeLineBreak(from layout: MenuBarLayout) -> MenuBarLayout {
        guard layout.lines.count == 2 else { return layout }
        return MenuBarLayout(lines: [layout.lines[0] + layout.lines[1]])
    }
}

private enum MenuBarLayoutEditorScope: Hashable {
    case all
    case provider(UsageProvider)
}

@MainActor
enum MenuBarLayoutEditorPersistence {
    static func activate(
        _ layout: MenuBarLayout,
        for provider: UsageProvider?,
        settings: SettingsStore)
    {
        settings.menuBarIconStyle = .iconAndPercent
        settings.setMenuBarLayout(layout, for: provider)
    }

    static func setSize(
        _ size: MenuBarLayoutSize,
        activating layout: MenuBarLayout,
        for provider: UsageProvider?,
        settings: SettingsStore)
    {
        settings.menuBarLayoutSize = size
        self.activate(layout, for: provider, settings: settings)
    }

    static func setGap(
        _ gap: MenuBarLayoutGap,
        activating layout: MenuBarLayout,
        for provider: UsageProvider?,
        settings: SettingsStore)
    {
        settings.menuBarLayoutGap = gap
        self.activate(layout, for: provider, settings: settings)
    }
}

private struct MenuBarLayoutPaletteGroup: Identifiable {
    let id: String
    let title: String
    let tokens: [MenuBarLayoutToken]
    let includesLineBreak: Bool
}

@MainActor
struct MenuBarLayoutEditor: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    @State private var scope: MenuBarLayoutEditorScope = .all
    @State private var selectedPosition: MenuBarLayoutPosition?
    @State private var conditionalDraft: MenuBarLayoutConditionalDraft?

    private var layout: MenuBarLayout {
        switch self.scope {
        case .all:
            self.settings.menuBarLayoutForGlobalEditing(representativeProvider: self.scopedProvider)
        case let .provider(provider):
            self.settings.menuBarLayout(for: provider)
        }
    }

    private var preset: MenuBarLayoutPreset {
        MenuBarLayoutPreset.matching(self.layout)
    }

    private var providers: [UsageProvider] {
        self.store.enabledFirstPartyProvidersForDisplay()
    }

    private var scopedProvider: UsageProvider? {
        switch self.scope {
        case .all: self.providers.first
        case let .provider(provider): provider
        }
    }

    private var persistenceProvider: UsageProvider? {
        switch self.scope {
        case .all: nil
        case let .provider(provider): provider
        }
    }

    private var persistenceSnapshot: UsageSnapshot? {
        self.persistenceProvider.flatMap { self.store.snapshot(for: $0.instanceID) }
    }

    private var sizeBinding: Binding<MenuBarLayoutSize> {
        Binding(
            get: { self.settings.menuBarLayoutSize },
            set: { size in
                MenuBarLayoutEditorPersistence.setSize(
                    size,
                    activating: self.layout,
                    for: self.persistenceProvider,
                    settings: self.settings)
            })
    }

    private var gapBinding: Binding<MenuBarLayoutGap> {
        Binding(
            get: { self.settings.menuBarLayoutGap },
            set: { gap in
                MenuBarLayoutEditorPersistence.setGap(
                    gap,
                    activating: self.layout,
                    for: self.persistenceProvider,
                    settings: self.settings)
            })
    }

    private var paletteGroups: [MenuBarLayoutPaletteGroup] {
        [
            MenuBarLayoutPaletteGroup(
                id: "identity",
                title: L("menu_bar_layout_group_identity"),
                tokens: [.icon, .providerName, .accountLabel],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "usage",
                title: L("menu_bar_layout_group_usage"),
                tokens: [
                    .percent(window: .session),
                    .percent(window: .weekly),
                    .percent(window: .scopedWeekly),
                ] + self.providerLaneTokens + [
                    .percent(window: .automatic),
                    .usageBar,
                    .pace(window: .session),
                    .pace(window: .weekly),
                    .pace(window: .automatic),
                ],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "time",
                title: L("menu_bar_layout_group_time"),
                tokens: MenuBarLayoutPaletteTokens.time,
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "money",
                title: L("menu_bar_layout_group_money"),
                tokens: [.balance, .costToday, .cost30d],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "structure",
                title: L("menu_bar_layout_group_structure"),
                tokens: [.separatorDot, .space],
                includesLineBreak: true),
        ]
    }

    private var providerLaneTokens: [MenuBarLayoutToken] {
        MenuBarLayoutLane.available(for: self.persistenceProvider, snapshot: self.persistenceSnapshot)
            .map { .lanePercent(lane: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header
            self.preview
            self.layoutStrip
            self.removeDropTarget

            Divider()

            ForEach(self.paletteGroups) { group in
                self.palette(group)
            }

            self.conditionalsPalette

            Divider()

            self.displayOptions
        }
        .padding(.vertical, 4)
        .onDeleteCommand {
            self.removeSelectedToken()
        }
        .sheet(item: self.$conditionalDraft) { draft in
            MenuBarLayoutConditionalEditorSheet(
                draft: draft,
                provider: self.persistenceProvider,
                existingNames: Set(
                    self.settings.menuBarLayoutConditionals.map {
                        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }),
                onSave: self.saveConditionalDraft)
        }

        .onChange(of: self.scope) { _, _ in
            self.selectedPosition = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Menu {
                Button(L("menu_bar_layout_scope_all")) {
                    self.scope = .all
                }
                if !self.providers.isEmpty {
                    Divider()
                }
                ForEach(self.providers, id: \.self) { provider in
                    Button(L(self.store.metadata(for: provider).displayName)) {
                        self.scope = .provider(provider)
                    }
                }
            } label: {
                Label(self.scopeLabel, systemImage: "scope")
            }
            .menuStyle(.button)
            .help(L("menu_bar_layout_scope_help"))

            if case let .provider(provider) = self.scope,
               self.settings.menuBarLayoutOverrides[provider] != nil
            {
                Button(L("menu_bar_layout_use_all")) {
                    self.settings.removeMenuBarLayoutOverride(for: provider)
                    self.selectedPosition = nil
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(MenuBarLayoutPreset.allCases) { preset in
                    Button(preset.label) {
                        self.applyPreset(preset)
                    }
                    .disabled(preset == .custom)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(self.preset.label)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.button)
            .accessibilityLabel(L("menu_bar_layout_preset"))
        }
    }

    private var scopeLabel: String {
        switch self.scope {
        case .all:
            L("menu_bar_layout_scope_all")
        case let .provider(provider):
            L(self.store.metadata(for: provider).displayName)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("menu_bar_layout_live_preview"))
                .font(.caption)
                .foregroundStyle(.secondary)
            MenuBarLayoutPreview(
                layout: self.layout,
                provider: self.scopedProvider,
                settings: self.settings,
                store: self.store)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.background.opacity(0.75)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.separator.opacity(0.65), lineWidth: 1))
        }
    }

    private var layoutStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("menu_bar_layout_strip"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if self.layout.lines.count == 2 {
                    Button(L("menu_bar_layout_remove_line_break")) {
                        self.write(MenuBarLayoutEditorMutations.removeLineBreak(from: self.layout))
                    }
                    .buttonStyle(.link)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(self.layout.lines.enumerated()), id: \.offset) { lineIndex, _ in
                    self.layoutLine(lineIndex)
                }
            }
        }
    }

    private func layoutLine(_ lineIndex: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                let line = self.layout.lines[lineIndex]
                ForEach(Array(line.enumerated()), id: \.offset) { index, token in
                    let position = MenuBarLayoutPosition(line: lineIndex, index: index)
                    MenuBarLayoutEditorChip(
                        title: self.chipTitle(for: token),
                        systemImage: token.editorSystemImage,
                        isSelected: self.selectedPosition == position,
                        accessibilityLabel: self.chipAccessibilityLabel(for: token),
                        accessibilityHint: L("menu_bar_layout_chip_hint"),
                        dragItem: .placed(token, at: position, in: self.layout),
                        activate: { self.selectedPosition = position },
                        removeActionTitle: L("Remove"),
                        remove: { self.remove(at: position) })
                        .dropDestination(for: MenuBarLayoutDragItem.self) { items, _ in
                            self.insert(items.first, at: position)
                        }
                        .contextMenu {
                            if case let .conditional(id) = token,
                               let conditional = self.settings.menuBarLayoutConditionals
                                   .first(where: { $0.id == id })
                            {
                                Button(L("menu_bar_layout_conditional_edit")) {
                                    self.conditionalDraft = MenuBarLayoutConditionalDraft(
                                        mode: .edit(id),
                                        conditional: conditional)
                                }
                            }
                        }
                }
                if line.isEmpty {
                    Text(L("menu_bar_layout_empty_line"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.secondary.opacity(0.35)))
        .dropDestination(for: MenuBarLayoutDragItem.self) { items, _ in
            self.insert(
                items.first,
                at: MenuBarLayoutPosition(line: lineIndex, index: self.layout.lines[lineIndex].count))
        }
        .accessibilityLabel(L("menu_bar_layout_line", lineIndex + 1))
    }

    /// Trash zone. Accepts drops and doubles as a plain click target so a selected token can be
    /// removed without dragging or reaching for the Delete key.
    private var removeDropTarget: some View {
        let canRemoveSelection = self.selectedPosition != nil
        return HStack(spacing: 6) {
            Image(systemName: "trash")
            Text(canRemoveSelection
                ? L("menu_bar_layout_remove_selected")
                : L("menu_bar_layout_drag_remove"))
        }
        .font(.caption)
        .foregroundStyle(canRemoveSelection ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.secondary.opacity(canRemoveSelection ? 0.12 : 0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture {
            self.removeSelectedToken()
        }
        .dropDestination(for: MenuBarLayoutDragItem.self) { items, _ in
            guard let item = items.first, item.source != nil else { return false }
            let updated = MenuBarLayoutEditorMutations.remove(item, from: self.layout)
            guard updated != self.layout else { return false }
            self.write(updated)
            self.selectedPosition = nil
            return true
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L("menu_bar_layout_drag_remove"))
        .accessibilityAction {
            self.removeSelectedToken()
        }
    }

    private func palette(_ group: MenuBarLayoutPaletteGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
                alignment: .leading,
                spacing: 6)
            {
                ForEach(group.tokens, id: \.self) { token in
                    MenuBarLayoutEditorChip(
                        title: token.editorLabel(
                            provider: self.persistenceProvider,
                            snapshot: self.persistenceSnapshot),
                        systemImage: token.editorSystemImage,
                        accessibilityLabel: token.editorAccessibilityLabel(
                            provider: self.persistenceProvider,
                            snapshot: self.persistenceSnapshot),
                        accessibilityHint: L("menu_bar_layout_palette_hint"),
                        dragItem: .palette(token),
                        activate: {
                            self.write(MenuBarLayoutEditorMutations.append(token, to: self.layout))
                        })
                }
                if group.includesLineBreak {
                    MenuBarLayoutEditorChip(
                        title: L("menu_bar_layout_token_line_break"),
                        systemImage: "arrow.turn.down.right",
                        isDisabled: self.layout.lines.count == 2,
                        accessibilityLabel: L("menu_bar_layout_token_line_break"),
                        accessibilityHint: L("menu_bar_layout_palette_hint"),
                        dragItem: .lineBreak,
                        activate: {
                            self.write(MenuBarLayoutEditorMutations.addLineBreak(to: self.layout))
                        })
                }
            }
        }
    }

    private var conditionalsPalette: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("menu_bar_layout_group_conditionals"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    self.conditionalDraft = MenuBarLayoutConditionalDraft(
                        mode: .create,
                        conditional: .makeDefault())
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help(L("menu_bar_layout_conditional_add"))
                .accessibilityLabel(L("menu_bar_layout_conditional_add"))
            }

            if self.settings.menuBarLayoutConditionals.isEmpty {
                Text(L("menu_bar_layout_conditional_none"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                MenuBarLayoutChipFlowLayout(spacing: 6) {
                    ForEach(self.settings.menuBarLayoutConditionals, id: \.id) { conditional in
                        self.conditionalPaletteChip(conditional: conditional)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func conditionalPaletteChip(
        conditional: MenuBarLayoutConditional)
        -> some View
    {
        MenuBarLayoutEditorChip(
            title: conditional.displayName,
            systemImage: "switch.2",
            accessibilityLabel: conditional.displayName,
            dragItem: .palette(.conditional(id: conditional.id)),
            activate: {
                self.write(MenuBarLayoutEditorMutations.append(.conditional(id: conditional.id), to: self.layout))
            })
            .contextMenu {
                Button(L("menu_bar_layout_conditional_edit")) {
                    self.conditionalDraft = MenuBarLayoutConditionalDraft(
                        mode: .edit(conditional.id),
                        conditional: conditional)
                }
                Button(L("menu_bar_layout_conditional_duplicate")) {
                    self.duplicateConditional(conditional)
                }
                Button(L("menu_bar_layout_conditional_remove"), role: .destructive) {
                    self.settings.removeMenuBarLayoutConditional(id: conditional.id)
                }
            }
    }

    private func duplicateConditional(_ conditional: MenuBarLayoutConditional) {
        let existingNames = Set(self.settings.menuBarLayoutConditionals.map { $0.name.lowercased() })
        let copyName = MenuBarLayoutConditional.uniqueCopyName(
            basedOn: conditional.name,
            existingNames: existingNames)
        let copy = MenuBarLayoutConditional(
            name: copyName,
            clauses: conditional.clauses,
            thenToken: conditional.thenToken,
            elseToken: conditional.elseToken)
        self.settings.menuBarLayoutConditionals.append(copy)
    }

    private var displayOptions: some View {
        HStack(spacing: 18) {
            Picker(L("menu_bar_layout_size"), selection: self.sizeBinding) {
                ForEach(MenuBarLayoutSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.menu)

            Picker(L("menu_bar_layout_gap"), selection: self.gapBinding) {
                ForEach(MenuBarLayoutGap.allCases) { gap in
                    Text(gap.label).tag(gap)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                Text(L("menu_bar_layout_vertical_adjustment"))
                    .lineLimit(1)
                    .fixedSize()

                TextField(
                    "",
                    value: self.$settings.menuBarLayoutVerticalAdjustment,
                    format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)

                Stepper(value: self.$settings.menuBarLayoutVerticalAdjustment, in: -20...20, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
            }

            Spacer()

            Text(L("menu_bar_layout_keyboard_hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func applyPreset(_ preset: MenuBarLayoutPreset) {
        guard let layout = preset.layout else { return }
        self.selectedPosition = nil
        self.write(layout)
    }

    private func insert(_ item: MenuBarLayoutDragItem?, at position: MenuBarLayoutPosition) -> Bool {
        guard let item else { return false }
        let updated = MenuBarLayoutEditorMutations.insert(item, at: position, in: self.layout)
        guard updated != self.layout else { return false }
        self.write(updated)
        self.selectedPosition = nil
        return true
    }

    private func removeSelectedToken() {
        guard let selectedPosition else { return }
        self.remove(at: selectedPosition)
    }

    private func remove(at position: MenuBarLayoutPosition) {
        let updated = MenuBarLayoutEditorMutations.remove(at: position, from: self.layout)
        guard updated != self.layout else { return }
        self.write(updated)
        self.selectedPosition = nil
    }

    private func saveConditionalDraft(_ draft: MenuBarLayoutConditionalDraft) {
        switch draft.mode {
        case .create:
            self.settings.menuBarLayoutConditionals.append(draft.conditional)
        case let .edit(id):
            guard let index = self.settings.menuBarLayoutConditionals.firstIndex(where: { $0.id == id })
            else { return }
            self.settings.menuBarLayoutConditionals[index] = draft.conditional
        }
    }

    private func chipTitle(for token: MenuBarLayoutToken) -> String {
        if case let .conditional(id) = token {
            return self.settings.menuBarLayoutConditionals
                .first(where: { $0.id == id })?.displayName
                ?? L("menu_bar_layout_token_conditional")
        }
        return token.editorLabel(provider: self.persistenceProvider, snapshot: self.persistenceSnapshot)
    }

    private func chipAccessibilityLabel(for token: MenuBarLayoutToken) -> String {
        if case .conditional = token {
            return self.chipTitle(for: token)
        }
        return token.editorAccessibilityLabel(
            provider: self.persistenceProvider,
            snapshot: self.persistenceSnapshot)
    }

    private func write(_ layout: MenuBarLayout) {
        MenuBarLayoutEditorPersistence.activate(
            layout,
            for: self.persistenceProvider,
            settings: self.settings)
    }
}

struct MenuBarLayoutChipLabel: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: self.systemImage)
                .font(.caption.weight(.medium))
            Text(self.title)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(self.isSelected ? Color.white : Color.primary)
        .background(
            Capsule(style: .continuous)
                .fill(self.isSelected ? Color.accentColor : Color.secondary.opacity(0.12)))
        .overlay(
            Capsule(style: .continuous)
                .stroke(self.isSelected ? Color.clear : Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

/// Left-aligned wrapping row layout for palette chips.
///
/// The conditionals palette holds user-named chips of widely varying width. An adaptive
/// `LazyVGrid` would size them into equal columns and spread the leftover pane width between
/// them, and a plain `HStack` would push later chips outside the settings pane; this places each
/// chip at its natural width and wraps to the next row.
struct MenuBarLayoutChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Pure packing rule: subview indices grouped into rows that each stay within `maxWidth`.
    /// Kept separate from `Layout` so the wrapping contract is testable without faking subviews.
    /// A chip wider than `maxWidth` still occupies its own row rather than being dropped.
    static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let advance = current.isEmpty ? width : spacing + width
            if !current.isEmpty, currentWidth + advance > maxWidth {
                rows.append(current)
                current = [index]
                currentWidth = width
                continue
            }
            current.append(index)
            currentWidth += advance
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.rows(
            widths: sizes.map(\.width),
            maxWidth: proposal.width ?? .infinity,
            spacing: self.spacing)
        let rowWidths = rows.map { row in
            row.reduce(CGFloat.zero) { $0 + sizes[$1].width }
                + CGFloat(max(0, row.count - 1)) * self.spacing
        }
        let rowHeights = rows.map { row in
            row.reduce(CGFloat.zero) { max($0, sizes[$1].height) }
        }
        return CGSize(
            width: rowWidths.max() ?? 0,
            height: rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * self.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: self.spacing)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.reduce(CGFloat.zero) { max($0, sizes[$1].height) }
            var x = bounds.minX
            for index in row {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + self.spacing
            }
            y += rowHeight + self.spacing
        }
    }
}

@MainActor
struct MenuBarLayoutPreview: View {
    let layout: MenuBarLayout
    let provider: UsageProvider?
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    private let renderer = MenuBarLayoutRenderer()

    var body: some View {
        let provider = self.provider ?? .codex
        let snapshot = self.store.snapshot(for: provider.instanceID)
        let data = snapshot.map { self.liveData(provider: provider, snapshot: $0) }
            ?? self.representativeData(provider: provider)
        let icon = ProviderBrandIcon.image(for: provider)
        let minute = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
        let rendered = self.renderer.render(
            layout: self.layout,
            data: data,
            icon: icon,
            options: MenuBarLayoutRenderOptions(
                size: self.settings.menuBarLayoutSize,
                highContrast: self.settings.menuBarHighContrastOnInactiveDisplays,
                showUsed: self.settings.usageBarsShowUsed,
                conditionals: self.settings.menuBarLayoutConditionals,
                appearanceName: "preview",
                isDebugApp: false,
                now: minute,
                verticalAdjustment: self.settings.menuBarLayoutVerticalAdjustment))
        MenuBarLayoutPreviewText(rendered: rendered)
    }

    func liveData(provider: UsageProvider, snapshot: UsageSnapshot) -> MenuBarLayoutRenderData {
        let now = Date()
        let session: RateWindow?
        let weekly: RateWindow?
        let rawAutomatic: RateWindow?
        let primary: RateWindow?
        let secondary: RateWindow?
        let tertiary = snapshot.tertiary
        if provider == .codex,
           let projection = self.store.codexConsumerProjectionIfNeeded(
               for: provider,
               surface: .menuBar,
               snapshotOverride: snapshot,
               now: now)
        {
            session = projection.menuBarSelectableRateWindow(for: .session)
            weekly = projection.menuBarSelectableRateWindow(for: .weekly)
            rawAutomatic = projection.automaticMenuBarWindow()
            primary = session
            secondary = weekly
        } else {
            let semanticWindows = MenuBarLayoutSemanticWindowResolver.windows(
                provider: provider,
                snapshot: snapshot)
            session = semanticWindows.session
            weekly = semanticWindows.weekly
            // Provider-specific by design: Mistral's automatic lane can explicitly select its Monthly Plan window.
            let automaticPreference = provider == .mistral
                ? self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
                : .automatic
            rawAutomatic = MenuBarMetricWindowResolver.rateWindow(
                preference: automaticPreference,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
                antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
                now: now)
            primary = snapshot.primary
            secondary = snapshot.secondary
        }
        let automatic = MenuBarLayoutAutomaticWindowDisplayNormalizer.normalized(
            provider: provider,
            snapshot: snapshot,
            window: rawAutomatic)
        let scopedNamed = MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot)
        let paceWindow = weekly ?? automatic
        // Bind the pace itself: `etaSeconds` is the numeric run-out conditional predicates compare.
        let pace = paceWindow.flatMap {
            self.store.weeklyPace(
                provider: provider,
                window: $0,
                now: now)
        }
        let runsOut = pace
            .flatMap { UsagePaceText.weeklyDetail(provider: provider, pace: $0, now: now).rightLabel }
        let cost = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let costToday = MenuBarLayoutCostResolver.todayCostUSD(snapshot: cost, now: now)
        let balanceAmounts = MenuBarLayoutBalanceResolver.balanceAmountsUSD(
            provider: provider,
            snapshot: snapshot)
        // Thresholds are USD, and `convertedCost` returns the source amount unchanged when no rate
        // exists, so keep the datum only when the conversion actually landed in USD.
        let toUSD = { (value: Double) -> Double? in
            let converted = UsageFormatter.convertedCost(
                value,
                preferredCurrency: "USD",
                providerCurrency: cost?.currencyCode)
            return converted.currencyCode == "USD" ? converted.value : nil
        }
        let automaticRenderWindow = MenuBarLayoutRenderWindow(automatic)
        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: provider.rawValue,
            providerName: L(self.store.metadata(for: provider).displayName),
            accountLabel: self.settings.hidePersonalInfo ? nil : snapshot.accountEmail(for: provider),
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(primary),
            secondary: MenuBarLayoutRenderWindow(secondary),
            tertiary: MenuBarLayoutRenderWindow(tertiary),
            session: MenuBarLayoutRenderWindow(session),
            weekly: MenuBarLayoutRenderWindow(weekly),
            scopedWeekly: MenuBarLayoutRenderWindow(scopedNamed?.window),
            scopedWeeklyTitle: scopedNamed?.title,
            automatic: automaticRenderWindow,
            // Provider-specific by design: Mistral uses spend text when its automatic lane has no percentage window.
            automaticText: provider == .mistral && automaticRenderWindow == nil
                ? StatusItemController.mistralSpendDisplayText(snapshot: snapshot)
                : nil,
            sessionPace: self.store.menuBarLayoutPaceText(provider: provider, window: session, now: now),
            weeklyPace: self.store.menuBarLayoutPaceText(
                provider: provider,
                window: weekly,
                now: now,
                minimumElapsedPercent: 1),
            automaticPace: self.store.menuBarLayoutPaceText(provider: provider, window: automatic, now: now),
            runsOut: runsOut,
            balance: MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot),
            costToday: costToday.map {
                UsageFormatter.currencyString($0, currencyCode: cost?.currencyCode ?? "USD")
            },
            cost30d: cost?.last30DaysCostUSD.map {
                UsageFormatter.currencyString($0, currencyCode: cost?.currencyCode ?? "USD")
            },
            metrics: MenuBarLayoutRenderMetrics(
                sessionPaceDelta: self.store.menuBarLayoutPaceDelta(
                    provider: provider,
                    window: session,
                    now: now),
                weeklyPaceDelta: self.store.menuBarLayoutPaceDelta(
                    provider: provider,
                    window: weekly,
                    now: now,
                    minimumElapsedPercent: 1),
                automaticPaceDelta: self.store.menuBarLayoutPaceDelta(
                    provider: provider,
                    window: automatic,
                    now: now),
                runsOutMinutes: pace?.etaSeconds.map { Int(($0 / 60).rounded()) },
                balanceRemainingUSD: balanceAmounts.remaining,
                balanceUsedUSD: balanceAmounts.used,
                costTodayUSD: costToday.flatMap(toUSD),
                cost30dUSD: cost?.last30DaysCostUSD.flatMap(toUSD)))
    }

    private func representativeData(provider: UsageProvider) -> MenuBarLayoutRenderData {
        let now = Date()
        let session = RateWindow(
            usedPercent: 37,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 60 * 60),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 62,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            resetDescription: nil)
        let scopedWeekly = RateWindow(
            usedPercent: 45,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            resetDescription: nil)
        // Sample pace comes straight from the pure calculation rather than the store, so the palette
        // preview stays deterministic before any snapshot has been fetched.
        let samplePace = { (window: RateWindow) -> String? in
            MenuBarDisplayText.paceText(pace: UsagePace.weekly(window: window, now: now))
        }
        let samplePaceDelta = { (window: RateWindow) -> Double? in
            UsagePace.weekly(window: window, now: now)?.deltaPercent.rounded()
        }
        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: "\(provider.rawValue)-representative",
            providerName: L(self.store.metadata(for: provider).displayName),
            accountLabel: self.settings.hidePersonalInfo ? nil : L("menu_bar_layout_sample_account"),
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: nil),
            primary: MenuBarLayoutRenderWindow(session),
            secondary: MenuBarLayoutRenderWindow(weekly),
            tertiary: MenuBarLayoutRenderWindow(scopedWeekly),
            session: MenuBarLayoutRenderWindow(session),
            weekly: MenuBarLayoutRenderWindow(weekly),
            scopedWeekly: MenuBarLayoutRenderWindow(scopedWeekly),
            scopedWeeklyTitle: "Fable only",
            automatic: MenuBarLayoutRenderWindow(session),
            automaticText: nil,
            sessionPace: samplePace(session),
            weeklyPace: samplePace(weekly),
            automaticPace: samplePace(session),
            runsOut: L("Runs out in %@", "1d 16h"),
            // Provider-specific by design: only OpenRouter previews the Balance palette token.
            balance: provider == .openrouter ? "$12.34" : nil,
            costToday: "$1.25",
            cost30d: "$20.00",
            metrics: MenuBarLayoutRenderMetrics(
                sessionPaceDelta: samplePaceDelta(session),
                weeklyPaceDelta: samplePaceDelta(weekly),
                automaticPaceDelta: samplePaceDelta(session),
                // 1d 16h == 40h, matching the sample `runsOut` text above.
                runsOutMinutes: 2400,
                balanceRemainingUSD: provider == .openrouter ? 12.34 : nil,
                balanceUsedUSD: provider == .openrouter ? 7.66 : nil,
                costTodayUSD: 1.25,
                cost30dUSD: 20))
    }
}

@MainActor
struct MenuBarLayoutPreviewText: NSViewRepresentable {
    let rendered: MenuBarLayoutRenderedTitle

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        self.configure(stack)
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        self.configure(stack)
    }

    private func configure(_ stack: NSStackView) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        // The live status button renders an extracted leading icon as `button.image`; mirror that
        // in the preview so an icon-leading (or icon-only) preset stays visible in Preferences.
        if let icon = self.rendered.leadingIcon {
            let imageView = NSImageView(image: icon)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = .labelColor
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(imageView)
        }
        let field = NSTextField(labelWithAttributedString: self.rendered.attributedTitle)
        field.alignment = .center
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 2
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(field)
        stack.setAccessibilityLabel(self.rendered.accessibilityLabel)
    }
}

extension MenuBarLayoutPreset {
    var label: String {
        switch self {
        case .iconAndPercent: L("menu_bar_layout_preset_icon_percent")
        case .iconOnly: L("menu_bar_layout_preset_icon_only")
        case .percentAndReset: L("menu_bar_layout_preset_percent_reset")
        case .compactStacked: L("menu_bar_layout_preset_compact_stacked")
        case .custom: L("menu_bar_layout_preset_custom")
        }
    }
}

extension MenuBarLayoutSize {
    var label: String {
        switch self {
        case .small: L("menu_bar_layout_size_small")
        case .regular: L("menu_bar_layout_size_regular")
        }
    }
}

extension MenuBarLayoutGap {
    var label: String {
        switch self {
        case .tight: L("menu_bar_layout_gap_tight")
        case .regular: L("menu_bar_layout_gap_regular")
        }
    }
}

extension MenuBarLayoutToken {
    func editorLabel(provider: UsageProvider?, snapshot: UsageSnapshot? = nil) -> String {
        if case let .lanePercent(lane) = self {
            return self.laneEditorLabel(lane: lane, provider: provider, snapshot: snapshot)
        }
        if let providerLabel = self.providerEditorLabel(provider: provider) {
            return providerLabel
        }
        return self.defaultEditorLabel
    }

    private func providerEditorLabel(provider: UsageProvider?) -> String? {
        guard let provider,
              let secondaryLabel = ProviderDescriptorRegistry.descriptor(for: provider).presentation
                  .menuBarLayoutSecondaryLabel
        else { return nil }
        let localizedLabel = L(secondaryLabel)
        return switch self {
        case .percent(window: .weekly): L("%@ %@", localizedLabel, "%")
        case .pace(window: .weekly): L("%@ %@", localizedLabel, L("display_mode_pace").lowercased())
        default: nil
        }
    }

    private var defaultEditorLabel: String {
        switch self {
        case .icon: L("menu_bar_layout_token_icon")
        case .providerName: L("menu_bar_layout_token_provider")
        case .accountLabel: L("menu_bar_layout_token_account")
        case .percent(window: .session): L("menu_bar_layout_token_session")
        case .percent(window: .weekly): L("menu_bar_layout_token_weekly")
        case .percent(window: .scopedWeekly): L("menu_bar_layout_token_scoped_weekly")
        case .percent(window: .automatic): L("menu_bar_layout_token_auto")
        case let .lanePercent(lane): L("%@ %@", lane.rawValue.capitalized, "%")
        case .pace(window: .session): L("menu_bar_layout_token_session_pace")
        case .pace(window: .weekly): L("menu_bar_layout_token_weekly_pace")
        case .pace(window: .scopedWeekly): L("menu_bar_layout_token_weekly_pace")
        case .pace(window: .automatic): L("menu_bar_layout_token_auto_pace")
        case .usageBar: L("menu_bar_layout_token_bar")
        case .resetCountdown: L("menu_bar_layout_token_resets_in")
        case .resetAbsolute: L("menu_bar_layout_token_reset_at")
        case .runsOut: L("menu_bar_layout_token_runs_out")
        case .runsOutCompact: "\(L("menu_bar_layout_token_runs_out")) (compact)"
        case .balance: L("Balance")
        case .costToday: L("menu_bar_layout_token_cost_today")
        case .cost30d: L("menu_bar_layout_token_cost_30d")
        case .separatorDot: "·"
        case .space: L("menu_bar_layout_token_space")
        case .conditional: L("menu_bar_layout_token_conditional")
        case .hidden: L("menu_bar_layout_conditional_hide")
        }
    }

    private func laneEditorLabel(
        lane: MenuBarLayoutLane,
        provider: UsageProvider?,
        snapshot: UsageSnapshot?)
        -> String
    {
        guard let provider else { return L("%@ %@", lane.rawValue.capitalized, "%") }
        let label = MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot).label(for: lane)
        return L("%@ %@", label, "%")
    }

    func editorAccessibilityLabel(provider: UsageProvider?, snapshot: UsageSnapshot? = nil) -> String {
        switch self {
        case .separatorDot: L("menu_bar_layout_token_separator_accessibility")
        default: self.editorLabel(provider: provider, snapshot: snapshot)
        }
    }

    var editorSystemImage: String {
        switch self {
        case .icon: "app.dashed"
        case .providerName: "textformat"
        case .accountLabel: "person.crop.circle"
        case .percent, .lanePercent: "percent"
        case .pace: "speedometer"
        case .usageBar: "chart.bar.fill"
        case .resetCountdown: "timer"
        case .resetAbsolute: "clock"
        case .runsOut, .runsOutCompact: "hourglass.bottomhalf.filled"
        case .balance: "creditcard"
        case .costToday: "dollarsign.circle"
        case .cost30d: "calendar.badge.clock"
        case .separatorDot: "smallcircle.filled.circle"
        case .space: "space"
        case .conditional: "switch.2"
        case .hidden: "eye.slash"
        }
    }
}
