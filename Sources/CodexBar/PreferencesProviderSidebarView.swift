import AppKit
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ProviderSidebarListView: View {
    let providers: [UsageProvider]
    let orderedProviders: [UsageProvider]
    @Bindable var store: UsageStore
    let isEnabled: (UsageProvider) -> Binding<Bool>
    let subtitle: (UsageProvider) -> String
    @Binding var searchText: String
    @Binding var selection: UsageProvider?
    @Binding var sortAlphabetically: Bool
    let moveProviders: (IndexSet, Int) -> Void
    @State private var draggingProvider: UsageProvider?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ProviderSidebarSearchField(searchText: self.$searchText)
                ProviderSidebarSortToggle(isOn: self.$sortAlphabetically)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 0) {
                    if self.providers.isEmpty {
                        Text(L("No matching providers"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }

                    ForEach(self.providers, id: \.self) { provider in
                        ProviderSidebarRowView(
                            provider: provider,
                            store: self.store,
                            isEnabled: self.isEnabled(provider),
                            subtitle: self.subtitle(provider),
                            isSelected: self.selection == provider,
                            showsReorderHandle: !self.sortAlphabetically,
                            draggingProvider: self.$draggingProvider)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        self.selection == provider
                                            ? Color(nsColor: .selectedContentBackgroundColor)
                                            : Color.clear)
                                    .padding(.horizontal, 4))
                            .contentShape(Rectangle())
                            .onTapGesture { self.selection = provider }
                            .onDrop(
                                of: [UTType.plainText],
                                delegate: ProviderSidebarDropDelegate(
                                    item: provider,
                                    providers: self.orderedProviders,
                                    dragging: self.$draggingProvider,
                                    moveProviders: self.moveProviders))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8)))
        .overlay(
            RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous))
        .frame(minWidth: ProviderSettingsMetrics.sidebarWidth, maxWidth: ProviderSettingsMetrics.sidebarWidth)
    }
}

private struct ProviderSidebarSearchField: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(L("Search providers"), text: self.$searchText)
                .textFieldStyle(.plain)

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
    }
}

private struct ProviderSidebarSortToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            self.isOn.toggle()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.callout)
                .foregroundStyle(self.isOn ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(self.isOn
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(self.isOn
            ? L("Sorted alphabetically (enabled first) — click to use your custom order")
            : L("Sort providers alphabetically (enabled first)"))
        .accessibilityLabel(L("Sort providers alphabetically"))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}

@MainActor
private struct ProviderSidebarRowView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let isSelected: Bool
    let showsReorderHandle: Bool
    @Binding var draggingProvider: UsageProvider?

    var body: some View {
        let isRefreshing = self.store.refreshingProviders.contains(self.provider)
        let showStatus = self.store.statusChecksEnabled
        let statusText = self.statusText
        let palette = ProviderSidebarRowPalette(isSelected: self.isSelected)

        HStack(alignment: .center, spacing: 10) {
            if self.showsReorderHandle {
                ProviderSidebarReorderHandle(color: palette.tertiary)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                    .help(L("Drag to reorder"))
                    .onDrag {
                        self.draggingProvider = self.provider
                        return NSItemProvider(object: self.provider.rawValue as NSString)
                    }
            } else {
                // Inset the icon a touch so rows don't hug the left edge once the drag handle is gone.
                Color.clear.frame(width: 8, height: 1)
            }

            ProviderSidebarBrandIcon(provider: self.provider, color: palette.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.store.metadata(for: self.provider).displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(nsColor: palette.primary))

                    if showStatus {
                        ProviderStatusDot(indicator: self.store.statusIndicator(for: self.provider))
                    }

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: palette.secondary))
                    .lineLimit(2)
                    .frame(height: ProviderSettingsMetrics.sidebarSubtitleHeight, alignment: .topLeading)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard !self.isEnabled else { return self.subtitle }
        let lines = self.subtitle.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2 {
            let first = lines[0]
            let rest = lines.dropFirst().joined(separator: "\n")
            return "\(L("Disabled")) — \(first)\n\(rest)"
        }
        return "\(L("Disabled")) — \(self.subtitle)"
    }
}

private struct ProviderSidebarReorderHandle: View {
    let color: NSColor

    var body: some View {
        VStack(spacing: ProviderSettingsMetrics.reorderDotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: ProviderSettingsMetrics.reorderDotSpacing) {
                    Circle()
                        .frame(
                            width: ProviderSettingsMetrics.reorderDotSize,
                            height: ProviderSettingsMetrics.reorderDotSize)
                    Circle()
                        .frame(
                            width: ProviderSettingsMetrics.reorderDotSize,
                            height: ProviderSettingsMetrics.reorderDotSize)
                }
            }
        }
        .frame(
            width: ProviderSettingsMetrics.reorderHandleSize,
            height: ProviderSettingsMetrics.reorderHandleSize)
        .foregroundStyle(Color(nsColor: self.color))
        .accessibilityLabel(L("Reorder"))
    }
}

@MainActor
private struct ProviderSidebarBrandIcon: View {
    let provider: UsageProvider
    let color: NSColor

    var body: some View {
        if let brand = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: brand)
                .resizable()
                .scaledToFit()
                .frame(width: ProviderSettingsMetrics.iconSize, height: ProviderSettingsMetrics.iconSize)
                .foregroundStyle(Color(nsColor: self.color))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: ProviderSettingsMetrics.iconSize, weight: .regular))
                .foregroundStyle(Color(nsColor: self.color))
                .accessibilityHidden(true)
        }
    }
}

struct ProviderSidebarRowPalette {
    let primary: NSColor
    let secondary: NSColor
    let tertiary: NSColor

    init(isSelected: Bool) {
        if isSelected {
            let selectedText = NSColor.alternateSelectedControlTextColor
            self.primary = selectedText
            self.secondary = selectedText.withAlphaComponent(0.82)
            self.tertiary = selectedText.withAlphaComponent(0.65)
        } else {
            self.primary = .labelColor
            self.secondary = .secondaryLabelColor
            self.tertiary = .tertiaryLabelColor
        }
    }
}

private struct ProviderSidebarDropDelegate: DropDelegate {
    let item: UsageProvider
    let providers: [UsageProvider]
    @Binding var dragging: UsageProvider?
    let moveProviders: (IndexSet, Int) -> Void

    func dropEntered(info _: DropInfo) {
        guard let dragging, dragging != self.item else { return }
        guard let fromIndex = self.providers.firstIndex(of: dragging),
              let toIndex = self.providers.firstIndex(of: self.item)
        else { return }

        if fromIndex == toIndex { return }
        let adjustedIndex = toIndex > fromIndex ? toIndex + 1 : toIndex
        self.moveProviders(IndexSet(integer: fromIndex), adjustedIndex)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        self.dragging = nil
        return true
    }
}

private struct ProviderStatusDot: View {
    let indicator: ProviderStatusIndicator

    var body: some View {
        Circle()
            .fill(self.statusColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch self.indicator {
        case .none: .green
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        case .maintenance: .gray
        case .unknown: .gray
        }
    }
}
