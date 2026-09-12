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
        _ = settings.copilotSeatCreditEntitlementRaw
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
        let budgetExtrasBinding = context.binding(\.copilotBudgetExtrasEnabled)
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
                placement: .menuBar,
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
            ProviderCookieSourceUI.picker(
                id: "copilot-budget-cookie-source",
                context: context,
                source: \.copilotBudgetCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatically imports browser cookies for github.com budget extras.",
                        manual: "Paste a Cookie header from github.com.",
                        off: "GitHub cookies are disabled.")
                },
                title: "GitHub cookies",
                subtitle: "Automatically imports browser cookies for budget extras.",
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
        let seatEntitlementBinding = Binding(
            get: { context.settings.copilotEffectiveSeatCreditEntitlementRaw },
            set: { newValue in
                context.store.setCopilotSeatCreditEntitlement(newValue)
            })
        return [
            ProviderSettingsFieldDescriptor(
                id: "copilot-budget-cookie-header",
                title: "Manual GitHub Cookie header",
                subtitle: "Paste a github.com Cookie header. Treat this value like a password.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.copilotBudgetCookieHeader),
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
                }),
            ProviderSettingsFieldDescriptor(
                id: "copilot-enterprise-host",
                title: "Enterprise host",
                subtitle: "Optional. Enter your GitHub Enterprise host, for example octocorp.ghe.com. " +
                    "Leave blank for github.com.",
                kind: .plain,
                placeholder: "github.com",
                binding: context.binding(\.copilotEnterpriseHost),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "copilot-seat-credit-entitlement",
                title: "Included AI credits (per seat)",
                subtitle: "GitHub does not publish this value. Enter it to show a usage bar. " +
                    "Applies to the selected GitHub account.",
                kind: .plain,
                placeholder: "e.g. 3000",
                binding: seatEntitlementBinding,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "copilot-clear-default-allowance",
                        title: "Clear default allowance",
                        style: .bordered,
                        isVisible: {
                            !context.settings.tokenAccounts(for: .copilot).isEmpty &&
                                !context.settings.copilotSeatCreditEntitlementRaw.isEmpty
                        },
                        perform: { context.store.clearCopilotDefaultSeatCreditEntitlement() }),
                ],
                isVisible: nil),
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
                isVisible: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await CopilotLoginFlow.run(settings: context.controller.settings)
        return true
    }

    @MainActor
    func runTokenAccountPrimaryAction(context: ProviderSettingsContext) async {
        await CopilotLoginFlow.run(settings: context.settings)
    }
}
