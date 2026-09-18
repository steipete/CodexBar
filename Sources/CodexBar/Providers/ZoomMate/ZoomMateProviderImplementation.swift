import CodexBarCore
import Foundation

struct ZoomMateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zoommate

    /// ZoomMate is a web-cookie provider with no CLI/version detector, so the default detail line
    /// ("zoommate not detected") would misleadingly read as "provider not found". Match the other
    /// web-cookie providers (Cursor, Perplexity, Manus, …) and surface the source instead.
    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "zoommate-cookie-source",
                context: context,
                source: \.zoomMateCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatically signs in using your ZoomMate session cookies from Chrome."),
                        manual: L("Paste a cURL capture from the ZoomMate AI credit usage page."),
                        off: L("Paste a cURL capture from the ZoomMate AI credit usage page."))
                },
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .zoommate,
                        cookieSource: context.settings.zoomMateCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .zoommate,
                        cookieSource: { context.settings.zoomMateCookieSource },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "zoommate-cookie",
                title: "ZoomMate capture",
                subtitle: "Paste a full cURL capture from the ZoomMate AI credit usage page. " +
                    "The token expires approximately hourly, so you may need to re-paste periodically.",
                kind: .secure,
                placeholder: "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'authorization: ...'",
                binding: context.binding(\.zoomMateCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "zoommate-open-app",
                        title: "Open ZoomMate",
                        url: URL(string: "https://zoommate.zoom.us/#/?settings=credit-usage")),
                ],
                isVisible: { context.settings.zoomMateCookieSource == .manual }),
        ]
    }
}
