#if DEBUG
import CodexBarCore
import SwiftUI

extension ProvidersPane {
    func _test_binding(for provider: UsageProvider) -> Binding<Bool> {
        self.binding(for: provider)
    }

    func _test_providerSubtitle(_ provider: UsageProvider) -> String {
        self.providerSubtitle(provider)
    }

    func _test_menuBarMetricPicker(for provider: UsageProvider) -> ProviderSettingsPickerDescriptor? {
        self.menuBarMetricPicker(for: provider)
    }

    func _test_tokenAccountDescriptor(for provider: UsageProvider) -> ProviderSettingsTokenAccountsDescriptor? {
        self.tokenAccountDescriptor(for: provider)
    }

    func _test_menuCardModel(for provider: UsageProvider) -> UsageMenuCardView.Model {
        self.menuCardModel(for: provider)
    }
}

@MainActor
enum ProvidersPaneTestHarness {
    static func exercise(settings: SettingsStore, store: UsageStore) {
        self.prepareTestState(settings: settings, store: store)
        let pane = ProvidersPane(settings: settings, store: store)
        self.exercisePaneBasics(pane: pane)

        let descriptors = self.makeDescriptors()
        self.exerciseDetailViews(store: store, descriptors: descriptors)
    }

    private static func prepareTestState(settings: SettingsStore, store: UsageStore) {
        store.versions[.codex] = "1.0.0"
        store.versions[.claude] = "2.0.0 (build 123)"
        store.versions[.cursor] = nil
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            provider: .minimax)
        store._setErrorForTesting(String(repeating: "x", count: 200), provider: .cursor)
        store.lastSourceLabels[.minimax] = "cookies"
        store.refreshingProviders.insert(.codex)

        settings.claudeCookieSource = .manual
        settings.cursorCookieSource = .manual
        settings.opencodeCookieSource = .manual
        settings.factoryCookieSource = .manual
        settings.minimaxCookieSource = .manual
        settings.augmentCookieSource = .manual
    }

    private static func exercisePaneBasics(pane: ProvidersPane) {
        _ = pane._test_binding(for: .codex).wrappedValue
        _ = pane._test_providerSubtitle(.codex)
        _ = pane._test_providerSubtitle(.claude)
        _ = pane._test_providerSubtitle(.cursor)
        _ = pane._test_providerSubtitle(.opencode)
        _ = pane._test_providerSubtitle(.zai)
        _ = pane._test_providerSubtitle(.synthetic)
        _ = pane._test_providerSubtitle(.minimax)
        _ = pane._test_providerSubtitle(.kimi)
        _ = pane._test_providerSubtitle(.gemini)

        _ = pane._test_menuBarMetricPicker(for: .codex)
        _ = pane._test_menuBarMetricPicker(for: .gemini)
        _ = pane._test_menuBarMetricPicker(for: .zai)

        if let descriptor = pane._test_tokenAccountDescriptor(for: .claude) {
            _ = descriptor.isVisible?()
            _ = descriptor.accounts()
        }
    }

    private static func exerciseDetailViews(store: UsageStore, descriptors: ProviderListTestDescriptors) {
        var isEnabled = true
        let enabledBinding = Binding(get: { isEnabled }, set: { isEnabled = $0 })
        let pane = ProvidersPane(settings: store.settings, store: store)
        let model = pane._test_menuCardModel(for: .codex)
        var expanded = false
        let expandedBinding = Binding(get: { expanded }, set: { expanded = $0 })

        _ = ProviderDetailView(
            provider: .codex,
            store: store,
            isEnabled: enabledBinding,
            subtitle: "Subtitle",
            model: model,
            settingsPickers: [descriptors.picker],
            settingsToggles: [descriptors.toggle],
            settingsFields: [descriptors.fieldPlain, descriptors.fieldSecure],
            settingsTokenAccounts: descriptors.tokenAccountsEmpty,
            errorDisplay: ProviderErrorDisplay(preview: "Preview", full: "Full"),
            isErrorExpanded: expandedBinding,
            onCopyError: { _ in },
            onRefresh: {}).body
    }

    private static func makeDescriptors() -> ProviderListTestDescriptors {
        let toggleBinding = Binding(get: { true }, set: { _ in })
        let actionBordered = ProviderSettingsActionDescriptor(
            id: "action-bordered",
            title: "Bordered",
            style: .bordered,
            isVisible: { true },
            perform: { await Task.yield() })
        let actionLink = ProviderSettingsActionDescriptor(
            id: "action-link",
            title: "Link",
            style: .link,
            isVisible: { true },
            perform: { await Task.yield() })
        let toggle = ProviderSettingsToggleDescriptor(
            id: "toggle",
            title: "Toggle",
            subtitle: "Toggle subtitle",
            binding: toggleBinding,
            statusText: { "Status" },
            actions: [actionBordered, actionLink],
            isVisible: { true },
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
        let picker = ProviderSettingsPickerDescriptor(
            id: "picker",
            title: "Picker",
            subtitle: "Picker subtitle",
            dynamicSubtitle: nil,
            binding: Binding(get: { "a" }, set: { _ in }),
            options: [
                ProviderSettingsPickerOption(id: "a", title: "Option A"),
                ProviderSettingsPickerOption(id: "b", title: "Option B"),
            ],
            isVisible: { true },
            onChange: nil,
            trailingText: { "Trailing" })
        let fieldPlain = ProviderSettingsFieldDescriptor(
            id: "plain",
            title: "Field",
            subtitle: "Field subtitle",
            kind: .plain,
            placeholder: "Placeholder",
            binding: Binding(get: { "" }, set: { _ in }),
            actions: [actionBordered],
            isVisible: { true },
            onActivate: nil)
        let fieldSecure = ProviderSettingsFieldDescriptor(
            id: "secure",
            title: "Secure",
            subtitle: "Secure subtitle",
            kind: .secure,
            placeholder: "Secure",
            binding: Binding(get: { "" }, set: { _ in }),
            actions: [actionLink],
            isVisible: { true },
            onActivate: nil)
        let tokenAccountsEmpty = ProviderSettingsTokenAccountsDescriptor(
            id: "accounts-empty",
            title: "Accounts",
            subtitle: "Accounts subtitle",
            placeholder: "Token",
            supportsManualEntry: true,
            supportsTwoFieldEntry: false,
            addActionTitle: nil,
            addAction: nil,
            importAction: nil,
            provider: .codex,
            isVisible: { true },
            accounts: { [] },
            activeIndex: { 0 },
            setActiveIndex: { _ in },
            addAccount: { _, _, _ in },
            removeAccount: { _ in },
            openConfigFile: {},
            reloadFromDisk: {})

        return ProviderListTestDescriptors(
            toggle: toggle,
            picker: picker,
            fieldPlain: fieldPlain,
            fieldSecure: fieldSecure,
            tokenAccountsEmpty: tokenAccountsEmpty)
    }
}

private struct ProviderListTestDescriptors {
    let toggle: ProviderSettingsToggleDescriptor
    let picker: ProviderSettingsPickerDescriptor
    let fieldPlain: ProviderSettingsFieldDescriptor
    let fieldSecure: ProviderSettingsFieldDescriptor
    let tokenAccountsEmpty: ProviderSettingsTokenAccountsDescriptor
}
#endif
