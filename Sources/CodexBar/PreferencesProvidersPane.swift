import AppKit
import CodexBarCore
import SwiftUI

private enum ProviderListMetrics {
    static let rowSpacing: CGFloat = 12
    static let rowInsets = EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    static let dividerBottomInset: CGFloat = 8
    static let listTopPadding: CGFloat = 12
    static let checkboxSize: CGFloat = 18
    static let iconSize: CGFloat = 18
    static let reorderHandleSize: CGFloat = 12
    static let reorderDotSize: CGFloat = 2
    static let reorderDotSpacing: CGFloat = 3
    static let pickerLabelWidth: CGFloat = 92
}

@MainActor
struct ProvidersPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var expandedErrors: Set<UsageProvider> = []
    @State private var settingsStatusTextByID: [String: String] = [:]
    @State private var settingsLastAppActiveRunAtByID: [String: Date] = [:]
    @State private var activeConfirmation: ProviderSettingsConfirmationState?

    private var providers: [UsageProvider] { self.settings.orderedProviders() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderListView(
                providers: self.providers,
                store: self.store,
                isEnabled: { provider in self.binding(for: provider) },
                subtitle: { provider in self.providerSubtitle(provider) },
                settingsPickers: { provider in self.extraSettingsPickers(for: provider) },
                settingsToggles: { provider in self.extraSettingsToggles(for: provider) },
                settingsFields: { provider in self.extraSettingsFields(for: provider) },
                errorDisplay: { provider in self.providerErrorDisplay(provider) },
                isErrorExpanded: { provider in self.expandedBinding(for: provider) },
                onCopyError: { text in self.copyToPasteboard(text) },
                moveProviders: { fromOffsets, toOffset in
                    self.settings.moveProvider(fromOffsets: fromOffsets, toOffset: toOffset)
                })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.runSettingsDidBecomeActiveHooks()
        }
        .alert(
            self.activeConfirmation?.title ?? "",
            isPresented: Binding(
                get: { self.activeConfirmation != nil },
                set: { isPresented in
                    if !isPresented { self.activeConfirmation = nil }
                }),
            actions: {
                if let active = self.activeConfirmation {
                    Button(active.confirmTitle) {
                        active.onConfirm()
                        self.activeConfirmation = nil
                    }
                    Button("Cancel", role: .cancel) { self.activeConfirmation = nil }
                }
            },
            message: {
                if let active = self.activeConfirmation {
                    Text(active.message)
                }
            })
    }

    private func binding(for provider: UsageProvider) -> Binding<Bool> {
        let meta = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: meta) },
            set: { self.settings.setProviderEnabled(provider: provider, metadata: meta, enabled: $0) })
    }

    private func providerSubtitle(_ provider: UsageProvider) -> String {
        let meta = self.store.metadata(for: provider)
        let cliName = meta.cliName
        let version = self.store.version(for: provider)
        var versionText = version ?? "not detected"
        if provider == .claude, let parenRange = versionText.range(of: "(") {
            versionText = versionText[..<parenRange.lowerBound].trimmingCharacters(in: .whitespaces)
        }

        let usageText: String
        if let snapshot = self.store.snapshot(for: provider) {
            let relative = snapshot.updatedAt.relativeDescription()
            usageText = "usage fetched \(relative)"
        } else if self.store.isStale(provider: provider) {
            usageText = "last fetch failed"
        } else {
            usageText = "usage not fetched yet"
        }

        if cliName == "codex" {
            return "\(versionText) • \(usageText)"
        }

        // Cursor is web-based, no CLI version to detect
        if provider == .cursor {
            return "web • \(usageText)"
        }
        if provider == .zai {
            return "api • \(usageText)"
        }
        if provider == .minimax {
            return "api • \(usageText)"
        }

        let detail = "\(cliName) \(versionText) • \(usageText)"
        return detail
    }

    private func providerErrorDisplay(_ provider: UsageProvider) -> ProviderErrorDisplay? {
        guard self.store.isStale(provider: provider), let raw = self.store.error(for: provider) else { return nil }
        return ProviderErrorDisplay(
            preview: self.truncated(raw, prefix: ""),
            full: raw)
    }

    private func extraSettingsToggles(for provider: UsageProvider) -> [ProviderSettingsToggleDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsToggles(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsPickers(for provider: UsageProvider) -> [ProviderSettingsPickerDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsPickers(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsFields(for provider: UsageProvider) -> [ProviderSettingsFieldDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsFields(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func makeSettingsContext(provider: UsageProvider) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: provider,
            settings: self.settings,
            store: self.store,
            boolBinding: { keyPath in
                Binding(
                    get: { self.settings[keyPath: keyPath] },
                    set: { self.settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { self.settings[keyPath: keyPath] },
                    set: { self.settings[keyPath: keyPath] = $0 })
            },
            statusText: { id in
                self.settingsStatusTextByID[id]
            },
            setStatusText: { id, text in
                if let text {
                    self.settingsStatusTextByID[id] = text
                } else {
                    self.settingsStatusTextByID.removeValue(forKey: id)
                }
            },
            lastAppActiveRunAt: { id in
                self.settingsLastAppActiveRunAtByID[id]
            },
            setLastAppActiveRunAt: { id, date in
                if let date {
                    self.settingsLastAppActiveRunAtByID[id] = date
                } else {
                    self.settingsLastAppActiveRunAtByID.removeValue(forKey: id)
                }
            },
            requestConfirmation: { confirmation in
                self.activeConfirmation = ProviderSettingsConfirmationState(confirmation: confirmation)
            })
    }

    private func runSettingsDidBecomeActiveHooks() {
        for provider in UsageProvider.allCases {
            for toggle in self.extraSettingsToggles(for: provider) {
                guard let hook = toggle.onAppDidBecomeActive else { continue }
                Task { @MainActor in
                    await hook()
                }
            }
        }
    }

    private func truncated(_ text: String, prefix: String, maxLength: Int = 160) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > maxLength {
            let idx = message.index(message.startIndex, offsetBy: maxLength)
            message = "\(message[..<idx])…"
        }
        return prefix + message
    }

    private func expandedBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.expandedErrors.contains(provider) },
            set: { expanded in
                if expanded {
                    self.expandedErrors.insert(provider)
                } else {
                    self.expandedErrors.remove(provider)
                }
            })
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

@MainActor
private struct ProviderListView: View {
    let providers: [UsageProvider]
    @Bindable var store: UsageStore
    let isEnabled: (UsageProvider) -> Binding<Bool>
    let subtitle: (UsageProvider) -> String
    let settingsPickers: (UsageProvider) -> [ProviderSettingsPickerDescriptor]
    let settingsToggles: (UsageProvider) -> [ProviderSettingsToggleDescriptor]
    let settingsFields: (UsageProvider) -> [ProviderSettingsFieldDescriptor]
    let errorDisplay: (UsageProvider) -> ProviderErrorDisplay?
    let isErrorExpanded: (UsageProvider) -> Binding<Bool>
    let onCopyError: (String) -> Void
    let moveProviders: (IndexSet, Int) -> Void

    var body: some View {
        List {
            ForEach(self.providers, id: \.self) { provider in
                Section {
                    let fields = self.settingsFields(provider)
                    let toggles = self.settingsToggles(provider)
                    let pickers = self.settingsPickers(provider)
                    let isEnabled = self.isEnabled(provider).wrappedValue
                    let shouldShowDivider = provider != self.providers.last
                    let hasExtraRows = !(pickers.isEmpty && fields.isEmpty && toggles.isEmpty)
                    let showDividerOnProviderRow = shouldShowDivider && (!isEnabled || !hasExtraRows)

                    ProviderListProviderRowView(
                        provider: provider,
                        store: self.store,
                        isEnabled: self.isEnabled(provider),
                        subtitle: self.subtitle(provider),
                        errorDisplay: self.isEnabled(provider).wrappedValue ? self.errorDisplay(provider) : nil,
                        isErrorExpanded: self.isErrorExpanded(provider),
                        onCopyError: self.onCopyError)
                        .padding(.bottom, showDividerOnProviderRow ? 12 : 0)
                        .listRowInsets(self.rowInsets(withDivider: showDividerOnProviderRow))
                        .listRowSeparator(.hidden)
                        .providerSectionDivider(isVisible: showDividerOnProviderRow)

                    if isEnabled {
                        let lastPickerID = pickers.last?.id
                        ForEach(pickers) { picker in
                            let isLastPicker = picker.id == lastPickerID
                            let showDivider = shouldShowDivider && fields.isEmpty && toggles.isEmpty && isLastPicker

                            ProviderListPickerRowView(provider: provider, picker: picker)
                                .id(self.rowID(provider: provider, suffix: picker.id))
                                .padding(.bottom, showDivider ? 12 : 0)
                                .listRowInsets(self.rowInsets(withDivider: showDivider))
                                .listRowSeparator(.hidden)
                                .providerSectionDivider(isVisible: showDivider)
                        }
                        let lastFieldID = fields.last?.id
                        ForEach(fields) { field in
                            let isLastField = field.id == lastFieldID
                            let showDivider = shouldShowDivider && toggles.isEmpty && isLastField

                            ProviderListFieldRowView(provider: provider, field: field)
                                .id(self.rowID(provider: provider, suffix: field.id))
                                .padding(.bottom, showDivider ? 12 : 0)
                                .listRowInsets(self.rowInsets(withDivider: showDivider))
                                .listRowSeparator(.hidden)
                                .providerSectionDivider(isVisible: showDivider)
                        }
                        let lastToggleID = toggles.last?.id
                        ForEach(toggles) { toggle in
                            let isLastToggle = toggle.id == lastToggleID
                            let showDivider = shouldShowDivider && isLastToggle

                            ProviderListToggleRowView(provider: provider, toggle: toggle)
                                .id(self.rowID(provider: provider, suffix: toggle.id))
                                .padding(.bottom, showDivider ? 12 : 0)
                                .listRowInsets(self.rowInsets(withDivider: showDivider))
                                .listRowSeparator(.hidden)
                                .providerSectionDivider(isVisible: showDivider)
                        }
                    }
                } header: {
                    EmptyView()
                }
            }
            .onMove { fromOffsets, toOffset in
                self.moveProviders(fromOffsets, toOffset)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, ProviderListMetrics.listTopPadding)
    }

    private func rowInsets(withDivider: Bool) -> EdgeInsets {
        if withDivider {
            return EdgeInsets(
                top: ProviderListMetrics.rowInsets.top,
                leading: ProviderListMetrics.rowInsets.leading,
                bottom: ProviderListMetrics.dividerBottomInset,
                trailing: ProviderListMetrics.rowInsets.trailing)
        }
        return ProviderListMetrics.rowInsets
    }

    private func rowID(provider: UsageProvider, suffix: String) -> String {
        "\(provider.rawValue)-\(suffix)"
    }
}

@MainActor
private struct ProviderListBrandIcon: View {
    let provider: UsageProvider

    var body: some View {
        if let brand = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: brand)
                .resizable()
                .scaledToFit()
                .frame(width: ProviderListMetrics.iconSize, height: ProviderListMetrics.iconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: ProviderListMetrics.iconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private struct ProviderListProviderRowView: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool
    let subtitle: String
    let errorDisplay: ProviderErrorDisplay?
    @Binding var isErrorExpanded: Bool
    let onCopyError: (String) -> Void
    @State private var isHovering = false
    @FocusState private var isToggleFocused: Bool

    var body: some View {
        let titleIndent = ProviderListMetrics.iconSize + 8
        let isRefreshing = self.store.refreshingProviders.contains(self.provider)
        let showReorderHandle = self.isHovering || self.isToggleFocused

        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            ProviderListReorderHandle(isVisible: showReorderHandle)
                .padding(.top, 4)

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)
                .focused(self.$isToggleFocused)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProviderListBrandIcon(provider: self.provider)
                            .padding(.top, 1)
                        Text(self.store.metadata(for: self.provider).displayName)
                            .font(.subheadline.bold())
                        if isRefreshing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Refreshing…")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(self.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        // Refreshing moves to the title line for a tighter layout.
                    }
                    .padding(.leading, titleIndent)
                }
                .contentShape(Rectangle())
                .onTapGesture { self.isEnabled.toggle() }

                if let errorDisplay {
                    ProviderErrorView(
                        title: "Last \(self.store.metadata(for: self.provider).displayName) fetch failed:",
                        display: errorDisplay,
                        isExpanded: self.$isErrorExpanded,
                        onCopy: { self.onCopyError(errorDisplay.full) })
                        .padding(.top, 8)
                        .padding(.leading, titleIndent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }
}

@MainActor
private struct ProviderListReorderHandle: View {
    let isVisible: Bool

    var body: some View {
        VStack(spacing: ProviderListMetrics.reorderDotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: ProviderListMetrics.reorderDotSpacing) {
                    Circle()
                        .frame(
                            width: ProviderListMetrics.reorderDotSize,
                            height: ProviderListMetrics.reorderDotSize)
                    Circle()
                        .frame(
                            width: ProviderListMetrics.reorderDotSize,
                            height: ProviderListMetrics.reorderDotSize)
                }
            }
        }
        .frame(width: ProviderListMetrics.reorderHandleSize, height: ProviderListMetrics.reorderHandleSize)
        .foregroundStyle(.tertiary)
        .opacity(self.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: self.isVisible)
        .help("Drag to reorder")
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

@MainActor
private struct ProviderListSectionDividerView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.leading, ProviderListMetrics.reorderHandleSize + ProviderListMetrics.checkboxSize + 14)
            .padding(.trailing, 10)
    }
}

extension View {
    @ViewBuilder
    fileprivate func providerSectionDivider(isVisible: Bool) -> some View {
        overlay(alignment: .bottom) {
            if isVisible {
                ProviderListSectionDividerView()
            }
        }
    }
}

@MainActor
private struct ProviderListToggleRowView: View {
    let provider: UsageProvider
    let toggle: ProviderSettingsToggleDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            Color.clear
                .frame(width: ProviderListMetrics.reorderHandleSize, height: ProviderListMetrics.reorderHandleSize)

            Toggle("", isOn: self.toggle.binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            Color.clear
                .frame(width: ProviderListMetrics.iconSize, height: ProviderListMetrics.iconSize)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.toggle.title)
                        .font(.subheadline.weight(.semibold))
                    Text(self.toggle.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if self.toggle.binding.wrappedValue {
                    if let status = self.toggle.statusText?(), !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let actions = self.toggle.actions.filter { $0.isVisible?() ?? true }
                    if !actions.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(actions) { action in
                                Button(action.title) {
                                    Task { @MainActor in
                                        await action.perform()
                                    }
                                }
                                .applyProviderSettingsButtonStyle(action.style)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: self.toggle.binding.wrappedValue) { _, enabled in
            guard let onChange = self.toggle.onChange else { return }
            Task { @MainActor in
                await onChange(enabled)
            }
        }
        .task(id: self.toggle.binding.wrappedValue) {
            guard self.toggle.binding.wrappedValue else { return }
            guard let onAppear = self.toggle.onAppearWhenEnabled else { return }
            await onAppear()
        }
    }
}

@MainActor
private struct ProviderListPickerRowView: View {
    let provider: UsageProvider
    let picker: ProviderSettingsPickerDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            Color.clear
                .frame(width: ProviderListMetrics.reorderHandleSize, height: ProviderListMetrics.reorderHandleSize)

            Color.clear
                .frame(width: ProviderListMetrics.checkboxSize, height: ProviderListMetrics.checkboxSize)

            Color.clear
                .frame(width: ProviderListMetrics.iconSize, height: ProviderListMetrics.iconSize)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.picker.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: ProviderListMetrics.pickerLabelWidth, alignment: .leading)

                    Picker("", selection: self.picker.binding) {
                        ForEach(self.picker.options) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)

                    if let trailingText = self.picker.trailingText?(), !trailingText.isEmpty {
                        Text(trailingText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 4)
                    }

                    Spacer(minLength: 0)
                }

                let subtitle = self.picker.dynamicSubtitle?() ?? self.picker.subtitle
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: self.picker.binding.wrappedValue) { _, selection in
            guard let onChange = self.picker.onChange else { return }
            Task { @MainActor in
                await onChange(selection)
            }
        }
    }
}

@MainActor
private struct ProviderListFieldRowView: View {
    let provider: UsageProvider
    let field: ProviderSettingsFieldDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            Color.clear
                .frame(width: ProviderListMetrics.reorderHandleSize, height: ProviderListMetrics.reorderHandleSize)

            Color.clear
                .frame(width: ProviderListMetrics.checkboxSize, height: ProviderListMetrics.checkboxSize)

            Color.clear
                .frame(width: ProviderListMetrics.iconSize, height: ProviderListMetrics.iconSize)

            let trimmedTitle = self.field.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSubtitle = self.field.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHeader = !trimmedTitle.isEmpty || !trimmedSubtitle.isEmpty

            VStack(alignment: .leading, spacing: hasHeader ? 8 : 0) {
                if hasHeader {
                    VStack(alignment: .leading, spacing: 4) {
                        if !trimmedTitle.isEmpty {
                            Text(trimmedTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                        if !trimmedSubtitle.isEmpty {
                            Text(trimmedSubtitle)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                switch self.field.kind {
                case .plain:
                    TextField(self.field.placeholder ?? "", text: self.field.binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .onTapGesture { self.field.onActivate?() }
                case .secure:
                    SecureField(self.field.placeholder ?? "", text: self.field.binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .onTapGesture { self.field.onActivate?() }
                }

                let actions = self.field.actions.filter { $0.isVisible?() ?? true }
                if !actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(actions) { action in
                            Button(action.title) {
                                Task { @MainActor in
                                    await action.perform()
                                }
                            }
                            .applyProviderSettingsButtonStyle(action.style)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func applyProviderSettingsButtonStyle(_ style: ProviderSettingsActionDescriptor.Style) -> some View {
        switch style {
        case .bordered:
            self.buttonStyle(.bordered)
        case .link:
            self.buttonStyle(.link)
        }
    }
}

private struct ProviderErrorDisplay: Sendable {
    let preview: String
    let full: String
}

@MainActor
private struct ProviderErrorView: View {
    let title: String
    let display: ProviderErrorDisplay
    @Binding var isExpanded: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    self.onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy error")
            }

            Text(self.display.preview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if self.display.preview != self.display.full {
                Button(self.isExpanded ? "Hide details" : "Show details") { self.isExpanded.toggle() }
                    .buttonStyle(.link)
                    .font(.footnote)
            }

            if self.isExpanded {
                Text(self.display.full)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }
}

@MainActor
private struct ProviderSettingsConfirmationState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void

    init(confirmation: ProviderSettingsConfirmation) {
        self.title = confirmation.title
        self.message = confirmation.message
        self.confirmTitle = confirmation.confirmTitle
        self.onConfirm = confirmation.onConfirm
    }
}
