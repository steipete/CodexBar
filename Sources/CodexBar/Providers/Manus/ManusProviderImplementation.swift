import AppKit
import CodexBarCore
import Foundation

struct ManusProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .manus
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        if let url = URL(string: "https://manus.im") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.manusCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.manusCookieSource != .manual {
            settings.manusCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "manus-cookie-source",
                context: context,
                source: \.manusCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Automatically imports browser session cookies."),
                        manual: L("Paste the %@ value or a full Cookie header.", "session_id"),
                        off: L("%@ cookies are disabled.", "Manus"))
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "manus-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "session_id=...\n\nor paste just the session_id value",
                binding: context.binding(\.manusManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "manus-open-dashboard",
                        title: "Open Manus",
                        url: URL(string: "https://manus.im")),
                ],
                isVisible: { context.settings.manusCookieSource == .manual }),
        ]
    }
}
