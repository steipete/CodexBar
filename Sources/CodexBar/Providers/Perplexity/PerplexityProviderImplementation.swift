import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct PerplexityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .perplexity

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.perplexitySessionCookie
    }

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in
            context.settings.perplexitySessionCookie.isEmpty
                ? "session cookie not configured"
                : "session cookie configured"
        }
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "perplexity-session-cookie",
                title: "Session cookie",
                subtitle: "Paste your __Secure-next-auth.session-token cookie value from perplexity.ai.",
                kind: .secure,
                placeholder: "Paste session cookie…",
                binding: context.stringBinding(\.perplexitySessionCookie),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "perplexity-open-settings",
                        title: "Open Perplexity Account",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.perplexity.ai/settings/account") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensurePerplexitySessionCookieLoaded() }),
        ]
    }
}
