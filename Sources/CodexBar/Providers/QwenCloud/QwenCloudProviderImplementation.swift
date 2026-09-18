import CodexBarCore
import Foundation

struct QwenCloudProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .qwencloud

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "qwen-cloud-cookie-source",
                context: context,
                source: \.qwenCloudCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies from Qwen Cloud."),
                        manual: L("Paste a Cookie header from %@.", "home.qwencloud.com"),
                        off: L("%@ cookies are disabled.", "Qwen Cloud"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .qwencloud)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "qwen-cloud-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.qwenCloudCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "qwen-cloud-open-dashboard",
                        title: "Open Token Plan",
                        url: QwenCloudUsageFetcher.dashboardURL),
                ],
                isVisible: {
                    context.settings.qwenCloudCookieSource == .manual
                }),
        ]
    }
}
