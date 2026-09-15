import AppKit
import CodexBarCore
import Foundation

struct NotionProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .notion
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        if let url = URL(string: "https://app.notion.com/") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.notionCookieSource
        _ = settings.notionCookieHeader
        _ = settings.notionWorkspaceID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .notion(context.settings.notionSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "notion-cookie-source",
                context: context,
                source: \.notionCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Automatically imports the browser session cookie."),
                        manual: L("Paste a full cookie header or the %@ value.", "token_v2"),
                        off: L("%@ cookies are disabled.", "Notion"))
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "notion-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste the token_v2 value",
                binding: context.binding(\.notionCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "notion-open-usage",
                        title: "Open Usage Page",
                        url: URL(string: "https://app.notion.com/")),
                ],
                isVisible: { context.settings.notionCookieSource == .manual }),
            ProviderSettingsFieldDescriptor(
                id: "notion-workspace-id",
                title: "Workspace ID",
                subtitle: "Optional. Defaults to the first Business or Enterprise workspace on the account.",
                kind: .plain,
                placeholder: "00000000-0000-0000-0000-000000000000",
                binding: context.binding(\.notionWorkspaceID),
                actions: [],
                isVisible: nil),
        ]
    }
}
