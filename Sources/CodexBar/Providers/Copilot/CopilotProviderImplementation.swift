import AppKit
import CodexBarCore
import SwiftUI

struct CopilotProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .copilot
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "github api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.copilotAPIToken
        _ = settings.copilotEnterpriseHost
        _ = settings.copilotBudgetExtrasEnabled
        _ = settings.copilotBudgetCookieSource
        _ = settings.copilotBudgetCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .copilot(context.settings.copilotSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Add Account...", .addProviderAccount(.copilot))
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let budgetExtrasBinding = Binding(
            get: { context.settings.copilotBudgetExtrasEnabled },
            set: { enabled in
                context.settings.copilotBudgetExtrasEnabled = enabled
            })
        let budgetExtrasStatus: () -> String? = {
            if context.store.snapshot(for: .copilot)?.extraRateWindows?.isEmpty == false {
                return nil
            }
            if context.settings.copilotBudgetCookieSource == .manual,
               context.settings.copilotBudgetCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return [
                    "Paste a github.com Cookie header, then refresh Copilot.",
                    "Copilot reauth does not provide the GitHub web cookie used for budgets.",
                ].joined(separator: " ")
            }
            return [
                "Refresh Copilot to load budget bars.",
                "Budget extras require a logged-in github.com browser session or a manual Cookie header.",
            ].joined(separator: " ")
        }

        return [
            ProviderSettingsToggleDescriptor(
                id: "copilot-budget-extras",
                title: "Budget extras",
                subtitle: [
                    "Optional.",
                    "Turn this on to fetch configured GitHub Copilot budget limits and show them as extra bars.",
                ].joined(separator: " "),
                binding: budgetExtrasBinding,
                statusText: budgetExtrasStatus,
                actions: [],
                isVisible: nil,
                onChange: { enabled in
                    if enabled {
                        await context.store.refreshProvider(.copilot, allowDisabled: true)
                    } else {
                        context.store.clearCopilotBudgetExtras()
                    }
                },
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let extraWindows = context.store.snapshot(for: .copilot)?.extraRateWindows ?? []
        let cookieBinding = Binding(
            get: { context.settings.copilotBudgetCookieSource.rawValue },
            set: { raw in
                context.settings.copilotBudgetCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.copilotBudgetCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports browser cookies for github.com budget extras.",
                manual: "Paste a Cookie header from github.com.",
                off: "GitHub cookies are disabled.")
        }
        let options = [
            ProviderSettingsPickerOption(
                id: CopilotIconSecondaryWindowSelection.chat,
                title: "Chat"),
        ] + extraWindows.map { window in
            ProviderSettingsPickerOption(id: window.id, title: window.title)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "copilot-icon-secondary-window",
                title: "Menu bar secondary metric",
                subtitle: "Choose the second meter shown in the menu bar icon.",
                dynamicSubtitle: {
                    extraWindows.isEmpty
                        ? "Budget options appear after a refresh finds configured Copilot budgets."
                        : nil
                },
                binding: Binding(
                    get: {
                        let selected = context.settings.copilotIconSecondaryWindowID
                        if selected == CopilotIconSecondaryWindowSelection.chat {
                            return selected
                        }
                        return extraWindows.contains(where: { $0.id == selected })
                            ? selected
                            : CopilotIconSecondaryWindowSelection.chat
                    },
                    set: { selection in
                        context.settings.copilotIconSecondaryWindowID = selection
                    }),
                options: options,
                isVisible: { context.settings.copilotBudgetExtrasEnabled },
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "copilot-budget-cookie-source",
                title: "GitHub cookies",
                subtitle: "Automatically imports browser cookies for budget extras.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: { context.settings.copilotBudgetExtrasEnabled },
                onChange: { _ in
                    await context.store.refreshProvider(.copilot, allowDisabled: true)
                },
                trailingText: {
                    guard context.settings.copilotBudgetCookieSource != .manual else { return nil }
                    return ProviderCookieSourceUI.cachedTrailingText(provider: .copilot)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "copilot-budget-cookie-header",
                title: "Manual GitHub Cookie header",
                subtitle: "Paste a github.com Cookie header. Treat this value like a password.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.copilotBudgetCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "refresh-copilot-budget-cookie",
                        title: "Refresh budgets",
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.store.refreshProvider(.copilot, allowDisabled: true)
                        }),
                ],
                isVisible: {
                    context.settings.copilotBudgetExtrasEnabled &&
                        context.settings.copilotBudgetCookieSource == .manual
                },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "copilot-enterprise-host",
                title: "Enterprise host",
                subtitle: "Optional. Enter your GitHub Enterprise host, for example octocorp.ghe.com. " +
                    "Leave blank for github.com.",
                kind: .plain,
                placeholder: "github.com",
                binding: context.stringBinding(\.copilotEnterpriseHost),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "copilot-add-account",
                title: "GitHub Login",
                subtitle: "Add accounts via GitHub OAuth Device Flow on the selected host.",
                kind: .plain,
                placeholder: nil,
                binding: .constant(""),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "copilot-add-account-action",
                        title: "Add Account",
                        style: .bordered,
                        isVisible: { true },
                        perform: {
                            await CopilotLoginFlow.run(settings: context.settings)
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await CopilotLoginFlow.run(settings: context.controller.settings)
        return true
    }
}
