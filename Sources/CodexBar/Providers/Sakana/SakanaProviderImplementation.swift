import AppKit
import CodexBarCore
import Foundation

struct SakanaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .sakana

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.sakanaCookieHeader
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        SakanaSettingsReader.cookieHeader(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let subtitle = "Stored in ~/.codexbar/config.json. Copy the Sakana AI console Cookie request header."

        return [
            ProviderSettingsFieldDescriptor(
                id: "sakana-cookie",
                title: "Cookie header",
                subtitle: subtitle,
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.sakanaCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "sakana-open-dashboard",
                        title: "Open Sakana AI Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.sakana.ai/billing") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
