import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct ZedProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zed

    @MainActor
    func settingsActions(context _: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        [
            ProviderSettingsActionsDescriptor(
                id: "zed-sign-in",
                title: "Zed sign-in",
                subtitle: """
                Sign in from the Zed editor app (GitHub). CodexBar reads that Keychain session — a browser \
                login to dashboard.zed.dev is not enough. Token spend is only on the billing dashboard.
                """,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "zed-open-billing-dashboard",
                        title: "Open Billing Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://dashboard.zed.dev") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil),
        ]
    }
}
