import AppKit
import CodexBarCore
import CodexBarMacroSupport
import SwiftUI

@ProviderImplementationRegistration
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
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .copilot(context.settings.copilotSettingsSnapshot())
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Add Account...", .addProviderAccount(.copilot))
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "copilot-add-account",
                title: "GitHub Login",
                subtitle: "Requires authentication via GitHub Device Flow.",
                footerText: "The device code is copied to your clipboard. Paste it into the GitHub page with ⌘V.",
                kind: .secure,
                placeholder: "Sign in via button below",
                binding: context.stringBinding(\.copilotAPIToken),
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
