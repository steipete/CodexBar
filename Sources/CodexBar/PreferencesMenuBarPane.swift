import CodexBarCore
import SwiftUI

@MainActor
struct MenuBarPane: View {
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit

    @State private var isOverviewProviderPopoverPresented = false
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    static func overviewProviderLimitText(limit: Int = Self.maxOverviewProviders) -> String {
        L("overview_choose_providers", String(limit))
    }

    static func inactiveDisplayContrastAvailable(for style: MenuBarIconStyle) -> Bool {
        style == .iconAndPercent
    }

    var body: some View {
        Form {
            Section {
                SettingsMenuPicker(
                    selection: self.$settings.menuBarIconStyle,
                    options: MenuBarSettingsMenuOptions.iconStyles,
                    label: {
                        SettingsRowLabel(
                            L("menu_bar_style_title"),
                            subtitle: L("menu_bar_style_subtitle"))
                    },
                    optionLabel: { style in
                        Text(style.label)
                    })

                SettingsMenuPicker(
                    selection: self.$settings.menuBarDisplayMode,
                    options: MenuBarSettingsMenuOptions.displayModes,
                    label: {
                        SettingsRowLabel(
                            L("display_mode_title"),
                            subtitle: self.settings.menuBarDisplayMode.description)
                    },
                    optionLabel: { mode in
                        Text(mode.label)
                    })
                    .disabled(self.settings.menuBarIconStyle != .iconAndPercent)

                Toggle(isOn: self.$settings.menuBarShowsResetTimeWhenExhausted) {
                    SettingsRowLabel(
                        L("menu_bar_reset_when_exhausted_title"),
                        subtitle: L("menu_bar_reset_when_exhausted_subtitle"))
                }
                .disabled(
                    self.settings.menuBarIconStyle != .iconAndPercent
                        || self.settings.menuBarDisplayMode == .resetTime)

                Toggle(isOn: self.$settings.menuBarHighContrastOnInactiveDisplays) {
                    SettingsRowLabel(
                        L("menu_bar_inactive_display_contrast_title"),
                        subtitle: "\(MenuBarIconStyle.iconAndPercent.label): "
                            + L("menu_bar_inactive_display_contrast_subtitle"))
                }
                .disabled(!Self.inactiveDisplayContrastAvailable(for: self.settings.menuBarIconStyle))
            } header: {
                Text(L("section_icon"))
            }

            Section {
                Toggle(isOn: self.$settings.mergeIcons) {
                    SettingsRowLabel(L("merge_icons_title"), subtitle: L("merge_icons_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.switcherRowsOption,
                    options: MenuBarSettingsMenuOptions.switcherRows,
                    label: { Text(L("switcher_rows_title")) },
                    optionLabel: { option in
                        Text(option.label)
                    })
                    .disabled(!self.settings.mergeIcons)

                Toggle(isOn: self.$settings.menuBarShowsHighestUsage) {
                    SettingsRowLabel(
                        L("show_most_used_provider_title"),
                        subtitle: L("show_most_used_provider_subtitle"))
                }
                .disabled(!self.settings.mergeIcons)

                self.overviewProviderRow
                    .disabled(!self.settings.mergeIcons)
            } header: {
                Text(L("section_combined_icon"))
            }

            Section {
                Toggle(isOn: self.$settings.randomBlinkEnabled) {
                    SettingsRowLabel(L("surprise_me_title"), subtitle: L("surprise_me_subtitle"))
                }
            } header: {
                Text(L("section_animation"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .onAppear {
            self.reconcileOverviewSelection()
        }
        .onChange(of: self.settings.mergeIcons) { _, isEnabled in
            guard isEnabled else {
                self.isOverviewProviderPopoverPresented = false
                return
            }
            self.reconcileOverviewSelection()
        }
        .onChange(of: self.activeProvidersInOrder) { _, _ in
            if self.activeProvidersInOrder.isEmpty {
                self.isOverviewProviderPopoverPresented = false
            }
            self.reconcileOverviewSelection()
        }
    }

    private var overviewProviderRow: some View {
        LabeledContent {
            if self.showsOverviewConfigureButton {
                Button(L("configure")) {
                    self.isOverviewProviderPopoverPresented = true
                }
                .popover(isPresented: self.$isOverviewProviderPopoverPresented, arrowEdge: .bottom) {
                    self.overviewProviderPopover
                }
            }
        } label: {
            SettingsRowLabel(L("overview_tab_providers_title"), subtitle: self.overviewProviderSubtitle)
        }
    }

    private var overviewProviderSubtitle: String {
        if !self.settings.mergeIcons {
            L("overview_enable_merge_icons_hint")
        } else if self.activeProvidersInOrder.isEmpty {
            L("overview_no_providers_hint")
        } else {
            self.overviewProviderSelectionSummary
        }
    }

    private var overviewProviderPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.overviewProviderLimitText())
                .font(.headline)
            Text(L("overview_rows_follow_order"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.activeProvidersInOrder, id: \.self) { provider in
                        Toggle(
                            isOn: Binding(
                                get: { self.overviewSelectedProviders.contains(provider) },
                                set: { shouldSelect in
                                    self.setOverviewProviderSelection(provider: provider, isSelected: shouldSelect)
                                })) {
                            Text(self.providerDisplayName(provider))
                                .font(.body)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(
                            !self.overviewSelectedProviders.contains(provider) &&
                                self.overviewSelectedProviders.count >= Self.maxOverviewProviders)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 280)
    }

    private var activeProvidersInOrder: [UsageProvider] {
        self.store.enabledProviders()
    }

    private var overviewSelectedProviders: [UsageProvider] {
        self.settings.resolvedMergedOverviewProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private var showsOverviewConfigureButton: Bool {
        self.settings.mergeIcons && !self.activeProvidersInOrder.isEmpty
    }

    private var overviewProviderSelectionSummary: String {
        let selectedNames = self.overviewSelectedProviders.map(self.providerDisplayName)
        guard !selectedNames.isEmpty else { return L("overview_no_providers_selected") }
        return selectedNames.joined(separator: ", ")
    }

    private func providerDisplayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    private func setOverviewProviderSelection(provider: UsageProvider, isSelected: Bool) {
        _ = self.settings.setMergedOverviewProviderSelection(
            provider: provider,
            isSelected: isSelected,
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private func reconcileOverviewSelection() {
        _ = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }
}
