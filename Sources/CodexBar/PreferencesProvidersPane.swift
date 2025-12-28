import AppKit
import CodexBarCore
import SwiftUI

private enum ProviderListMetrics {
    static let rowSpacing: CGFloat = 12
    static let rowInsets = EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    static let checkboxSize: CGFloat = 18
    static let iconSize: CGFloat = 18
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
                sourceLabel: { provider in self.providerSourceLabel(provider) },
                statusLabel: { provider in self.providerStatusLabel(provider) },
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

        var detail = "\(cliName) \(versionText) • \(usageText)"
        if provider == .antigravity {
            detail += " • experimental"
        }
        return detail
    }

    private func providerSourceLabel(_ provider: UsageProvider) -> String {
        self.store.sourceLabel(for: provider)
    }

    private func providerStatusLabel(_ provider: UsageProvider) -> String {
        if let snapshot = self.store.snapshot(for: provider) {
            return snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)
        }
        if self.store.isStale(provider: provider) {
            return "failed"
        }
        return "not yet"
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
    let sourceLabel: (UsageProvider) -> String
    let statusLabel: (UsageProvider) -> String
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
                    ProviderListProviderRowView(
                        provider: provider,
                        store: self.store,
                        isEnabled: self.isEnabled(provider),
                        subtitle: self.subtitle(provider),
                        sourceLabel: self.sourceLabel(provider),
                        statusLabel: self.statusLabel(provider),
                        errorDisplay: self.isEnabled(provider).wrappedValue ? self.errorDisplay(provider) : nil,
                        isErrorExpanded: self.isErrorExpanded(provider),
                        onCopyError: self.onCopyError)
                        .listRowInsets(ProviderListMetrics.rowInsets)

                    if self.isEnabled(provider).wrappedValue {
                        ForEach(self.settingsFields(provider)) { field in
                            ProviderListFieldRowView(provider: provider, field: field)
                                .listRowInsets(ProviderListMetrics.rowInsets)
                        }
                        ForEach(self.settingsToggles(provider)) { toggle in
                            ProviderListToggleRowView(provider: provider, toggle: toggle)
                                .listRowInsets(ProviderListMetrics.rowInsets)
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
    let sourceLabel: String
    let statusLabel: String
    let errorDisplay: ProviderErrorDisplay?
    @Binding var isErrorExpanded: Bool
    let onCopyError: (String) -> Void

    var body: some View {
        let titleIndent = ProviderListMetrics.iconSize + 8
        let isRefreshing = self.store.refreshingProviders.contains(self.provider)

        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProviderListBrandIcon(provider: self.provider)
                            .padding(.top, 1)
                        Text(self.store.metadata(for: self.provider).displayName)
                            .font(.subheadline.bold())
                    }
                    Text(self.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, titleIndent)
                    HStack(spacing: 8) {
                        Text(self.sourceLabel)
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing…")
                        } else {
                            Text(self.statusLabel)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
    }
}

@MainActor
private struct ProviderListToggleRowView: View {
    let provider: UsageProvider
    let toggle: ProviderSettingsToggleDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
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
private struct ProviderListFieldRowView: View {
    let provider: UsageProvider
    let field: ProviderSettingsFieldDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: ProviderListMetrics.rowSpacing) {
            Color.clear
                .frame(width: ProviderListMetrics.checkboxSize, height: ProviderListMetrics.checkboxSize)

            Color.clear
                .frame(width: ProviderListMetrics.iconSize, height: ProviderListMetrics.iconSize)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.field.title)
                        .font(.subheadline.weight(.semibold))
                    Text(self.field.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch self.field.kind {
                case .plain:
                    TextField(self.field.placeholder ?? "", text: self.field.binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                case .secure:
                    SecureField(self.field.placeholder ?? "", text: self.field.binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
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
