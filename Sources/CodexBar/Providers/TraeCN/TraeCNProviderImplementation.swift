import AppKit
import CodexBarCore
import Foundation

struct TraeCNProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .traecn
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "traecn-cookie",
                title: L("Cookie"),
                subtitle: L(
                    "Paste a Cookie header from %@ (DevTools → Network → any api.trae.cn request).",
                    "www.trae.cn"),
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.traeCNCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "traecn-open-dashboard",
                        title: L("Open Trae CN Dashboard"),
                        url: URL(string: "https://www.trae.cn/dashboard")),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        guard let url = URL(string: "https://www.trae.cn/dashboard") else {
            return false
        }
        NSWorkspace.shared.open(url)
        return false
    }
}
