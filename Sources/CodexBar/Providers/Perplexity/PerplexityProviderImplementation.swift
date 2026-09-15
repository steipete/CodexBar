import AppKit
import CodexBarCore
import Foundation

struct PerplexityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .perplexity
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        if let url = URL(string: "https://www.perplexity.ai/") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "perplexity-cookie-source",
                context: context,
                source: \.perplexityCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Automatically imports browser session cookie."),
                        manual: L("Paste a full cookie header or the %@ value.", "__Secure-next-auth.session-token"),
                        off: L("%@ cookies are disabled.", "Perplexity"))
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "perplexity-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste the __Secure-next-auth.session-token value",
                binding: context.binding(\.perplexityManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "perplexity-open-usage",
                        title: "Open Usage Page",
                        url: URL(string: "https://www.perplexity.ai/account/usage")),
                ],
                isVisible: { context.settings.perplexityCookieSource == .manual }),
        ]
    }
}
