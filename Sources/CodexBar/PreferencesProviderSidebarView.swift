import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ProviderSidebarListView: View {
    let providers: [UsageProvider]
    @Bindable var store: UsageStore
    let isEnabled: (UsageProvider) -> Binding<Bool>
    let subtitle: (UsageProvider) -> String
    @Binding var selection: UsageProvider?
    let moveProviders: (IndexSet, Int) -> Void
    @State private var draggingProvider: UsageProvider?

    var body: some View {
        List(selection: self.$selection) {
            ForEach(self.providers, id: \.self) { provider in
                ProviderSidebarRowView(
                    provider: provider,
                    store: self.store,
                    isEnabled: self.isEnabled(provider),
                    subtitle: self.subtitle(provider),
                    draggingProvider: self.$draggingProvider)
                    .tag(provider)
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: ProviderSidebarDropDelegate(
                            item: provider,
                            providers: self.providers,
                            dragging: self.$draggingProvider,
                            moveProviders: self.moveProviders))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(
            RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous)
                .fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: ProviderSettingsMetrics.sidebarCornerRadius, style: .continuous))
        .frame(minWidth: ProviderSettingsMetrics.sidebarWidth, maxWidth: ProviderSettingsMetrics.sidebarWidth)
    }
}

@MainActor
private struct ProviderSidebarRowView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    @Binding var draggingProvider: UsageProvider?

    var body: some View {
        let isRefreshing = self.store.refreshingProviders.contains(self.provider)
        let showStatus = self.store.statusChecksEnabled
        let statusText = self.statusText

        HStack(alignment: .center, spacing: 10) {
            ProviderSidebarReorderHandle()
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .help(L10n.tr("settings.providers.sidebar.reorder.help", fallback: "Drag to reorder"))
                .onDrag {
                    self.draggingProvider = self.provider
                    return NSItemProvider(object: self.provider.rawValue as NSString)
                }

            ProviderSidebarBrandIcon(provider: self.provider)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.store.metadata(for: self.provider).displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

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
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: ProviderSettingsMetrics.sidebarSubtitleHeight, alignment: .topLeading)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard !self.isEnabled else { return self.subtitle }
        let lines = self.subtitle.split(separator: "\n", omittingEmptySubsequences: false)
        let format = L10n.tr("settings.providers.sidebar.status.disabled_prefix", fallback: "Disabled — %@")
        if lines.count >= 2 {
            let first = lines[0]
            let rest = lines.dropFirst().joined(separator: "\n")
            return String(format: format, locale: .current, "\(first)\n\(rest)")
        }
        return String(format: format, locale: .current, self.subtitle)
    }
}

private struct ProviderSidebarReorderHandle: View {
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
        .foregroundStyle(.tertiary)
        .accessibilityLabel(L10n.tr("settings.providers.sidebar.accessibility.reorder", fallback: "Reorder"))
    }
}

@MainActor
private struct ProviderSidebarBrandIcon: View {
    let provider: UsageProvider

    var body: some View {
        if let brand = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: brand)
                .resizable()
                .scaledToFit()
                .frame(width: ProviderSettingsMetrics.iconSize, height: ProviderSettingsMetrics.iconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: ProviderSettingsMetrics.iconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
