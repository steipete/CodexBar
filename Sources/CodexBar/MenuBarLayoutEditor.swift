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
        self.store.enabledProvidersForDisplay()
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
                    .percent(window: .automatic),
                    .usageBar,
                ],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "time",
                title: L("menu_bar_layout_group_time"),
                tokens: [.resetCountdown, .resetAbsolute, .runsOut],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "money",
                title: L("menu_bar_layout_group_money"),
                tokens: [.costToday, .cost30d],
                includesLineBreak: false),
            MenuBarLayoutPaletteGroup(
                id: "structure",
                title: L("menu_bar_layout_group_structure"),
                tokens: [.separatorDot, .space],
                includesLineBreak: true),
        ]
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

            Divider()

            self.displayOptions
        }
        .padding(.vertical, 4)
        .onDeleteCommand {
            self.removeSelectedToken()
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
                    Button {
                        self.selectedPosition = position
                    } label: {
                        MenuBarLayoutChipLabel(
                            title: token.editorLabel,
                            systemImage: token.editorSystemImage,
                            isSelected: self.selectedPosition == position)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .onKeyPress(keys: [.space, .return], phases: [.down]) { _ in
                        self.selectedPosition = position
                        return .handled
                    }
                    .draggable(MenuBarLayoutDragItem.placed(token, at: position, in: self.layout))
                    .dropDestination(for: MenuBarLayoutDragItem.self) { items, _ in
                        self.insert(items.first, at: position)
                    }
                    .accessibilityLabel(token.editorAccessibilityLabel)
                    .accessibilityHint(L("menu_bar_layout_chip_hint"))
                    .accessibilityAction(named: L("Remove")) {
                        self.remove(at: position)
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

    private var removeDropTarget: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
            Text(L("menu_bar_layout_drag_remove"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.secondary.opacity(0.06)))
        .dropDestination(for: MenuBarLayoutDragItem.self) { items, _ in
            guard let item = items.first, item.source != nil else { return false }
            let updated = MenuBarLayoutEditorMutations.remove(item, from: self.layout)
            guard updated != self.layout else { return false }
            self.write(updated)
            self.selectedPosition = nil
            return true
        }
        .accessibilityLabel(L("menu_bar_layout_drag_remove"))
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
                    Button {
                        self.write(MenuBarLayoutEditorMutations.append(token, to: self.layout))
                    } label: {
                        MenuBarLayoutChipLabel(
                            title: token.editorLabel,
                            systemImage: token.editorSystemImage,
                            isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .onKeyPress(keys: [.space, .return], phases: [.down]) { _ in
                        self.write(MenuBarLayoutEditorMutations.append(token, to: self.layout))
                        return .handled
                    }
                    .draggable(MenuBarLayoutDragItem.palette(token))
                    .accessibilityLabel(token.editorAccessibilityLabel)
                    .accessibilityHint(L("menu_bar_layout_palette_hint"))
                }
                if group.includesLineBreak {
                    Button {
                        self.write(MenuBarLayoutEditorMutations.addLineBreak(to: self.layout))
                    } label: {
                        MenuBarLayoutChipLabel(
                            title: L("menu_bar_layout_token_line_break"),
                            systemImage: "arrow.turn.down.right",
                            isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .onKeyPress(keys: [.space, .return], phases: [.down]) { _ in
                        self.write(MenuBarLayoutEditorMutations.addLineBreak(to: self.layout))
                        return .handled
                    }
                    .draggable(MenuBarLayoutDragItem.lineBreak)
                    .disabled(self.layout.lines.count == 2)
                    .accessibilityLabel(L("menu_bar_layout_token_line_break"))
                    .accessibilityHint(L("menu_bar_layout_palette_hint"))
                }
            }
        }
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

    private func write(_ layout: MenuBarLayout) {
        MenuBarLayoutEditorPersistence.activate(
            layout,
            for: self.persistenceProvider,
            settings: self.settings)
    }
}

private struct MenuBarLayoutChipLabel: View {
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

@MainActor
private struct MenuBarLayoutPreview: View {
    let layout: MenuBarLayout
    let provider: UsageProvider?
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    private let renderer = MenuBarLayoutRenderer()

    var body: some View {
        let provider = self.provider ?? .codex
        let snapshot = self.store.snapshot(for: provider)
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
                appearanceName: "preview",
                isDebugApp: false,
                now: minute))
        MenuBarLayoutPreviewText(rendered: rendered)
    }

    private func liveData(provider: UsageProvider, snapshot: UsageSnapshot) -> MenuBarLayoutRenderData {
        let now = Date()
        let session: RateWindow?
        let weekly: RateWindow?
        let automatic: RateWindow?
        if provider == .codex,
           let projection = self.store.codexConsumerProjectionIfNeeded(
               for: provider,
               surface: .menuBar,
               snapshotOverride: snapshot,
               now: now)
        {
            session = projection.menuBarSelectableRateWindow(for: .session)
            weekly = projection.menuBarSelectableRateWindow(for: .weekly)
            automatic = projection.visibleRateLanes.lazy
                .compactMap { projection.menuBarSelectableRateWindow(for: $0) }
                .first
        } else {
            let semanticWindows = MenuBarLayoutSemanticWindowResolver.windows(
                provider: provider,
                snapshot: snapshot)
            session = semanticWindows.session
            weekly = semanticWindows.weekly
            automatic = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
                antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
                now: now)
        }
        let paceWindow = weekly ?? automatic
        let runsOut = paceWindow
            .flatMap { self.store.weeklyPace(provider: provider, window: $0, now: now) }
            .flatMap { UsagePaceText.weeklyDetail(provider: provider, pace: $0, now: now).rightLabel }
        let cost = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let costToday = MenuBarLayoutCostResolver.todayCostUSD(snapshot: cost, now: now)
        return MenuBarLayoutRenderData(
            iconKey: provider.rawValue,
            providerName: L(self.store.metadata(for: provider).displayName),
            accountLabel: self.settings.hidePersonalInfo ? nil : snapshot.accountEmail(for: provider),
            session: MenuBarLayoutRenderWindow(session),
            weekly: MenuBarLayoutRenderWindow(weekly),
            automatic: MenuBarLayoutRenderWindow(automatic),
            runsOut: runsOut,
            costToday: costToday.map {
                UsageFormatter.currencyString($0, currencyCode: cost?.currencyCode ?? "USD")
            },
            cost30d: cost?.last30DaysCostUSD.map {
                UsageFormatter.currencyString($0, currencyCode: cost?.currencyCode ?? "USD")
            })
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
        return MenuBarLayoutRenderData(
            iconKey: "\(provider.rawValue)-representative",
            providerName: L(self.store.metadata(for: provider).displayName),
            accountLabel: self.settings.hidePersonalInfo ? nil : L("menu_bar_layout_sample_account"),
            session: MenuBarLayoutRenderWindow(session),
            weekly: MenuBarLayoutRenderWindow(weekly),
            automatic: MenuBarLayoutRenderWindow(session),
            runsOut: L("menu_bar_layout_sample_runs_out"),
            costToday: "$1.25",
            cost30d: "$20.00")
    }
}

@MainActor
private struct MenuBarLayoutPreviewText: NSViewRepresentable {
    let rendered: MenuBarLayoutRenderedTitle

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: self.rendered.attributedTitle)
        field.alignment = .center
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 2
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = self.rendered.attributedTitle
        field.setAccessibilityLabel(self.rendered.accessibilityLabel)
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
    var editorLabel: String {
        switch self {
        case .icon: L("menu_bar_layout_token_icon")
        case .providerName: L("menu_bar_layout_token_provider")
        case .accountLabel: L("menu_bar_layout_token_account")
        case .percent(window: .session): L("menu_bar_layout_token_session")
        case .percent(window: .weekly): L("menu_bar_layout_token_weekly")
        case .percent(window: .automatic): L("menu_bar_layout_token_auto")
        case .usageBar: L("menu_bar_layout_token_bar")
        case .resetCountdown: L("menu_bar_layout_token_resets_in")
        case .resetAbsolute: L("menu_bar_layout_token_reset_at")
        case .runsOut: L("menu_bar_layout_token_runs_out")
        case .costToday: L("menu_bar_layout_token_cost_today")
        case .cost30d: L("menu_bar_layout_token_cost_30d")
        case .separatorDot: "·"
        case .space: L("menu_bar_layout_token_space")
        }
    }

    var editorAccessibilityLabel: String {
        switch self {
        case .separatorDot: L("menu_bar_layout_token_separator_accessibility")
        default: self.editorLabel
        }
    }

    var editorSystemImage: String {
        switch self {
        case .icon: "app.dashed"
        case .providerName: "textformat"
        case .accountLabel: "person.crop.circle"
        case .percent: "percent"
        case .usageBar: "chart.bar.fill"
        case .resetCountdown: "timer"
        case .resetAbsolute: "clock"
        case .runsOut: "hourglass.bottomhalf.filled"
        case .costToday: "dollarsign.circle"
        case .cost30d: "calendar.badge.clock"
        case .separatorDot: "smallcircle.filled.circle"
        case .space: "space"
        }
    }
}
