import CodexBarCore
import Foundation

struct QoderProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .qoder

    @MainActor
    static func usageDashboardURL(settings: SettingsStore) -> URL {
        QoderProviderDescriptor.dashboardURL(
            settings: settings.resolvedCookieSettings(provider: .qoder, tokenOverride: nil),
            sourceLabel: nil)
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.qoderCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.qoderCookieSource != .manual {
            settings.qoderCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "qoder-cookie-source",
                context: context,
                source: \.qoderCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies.",
                        manual: "Paste a Cookie header or cURL capture from Qoder usage.",
                        off: "Qoder cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .qoder)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "qoder-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste a cURL capture from the Qoder usage page",
                binding: context.binding(\.qoderCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "qoder-open-usage",
                        title: "Open Qoder Usage",
                        url: Self.usageDashboardURL(settings: context.settings)),
                ],
                isVisible: { context.settings.qoderCookieSource == .manual }),
        ]
    }
}
