import AppKit
import CodexBarCore
import Foundation
import SwiftUI

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
        let cookieBinding = Binding(
            get: { context.settings.notionCookieSource.rawValue },
            set: { raw in
                context.settings.notionCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.notionCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports the browser session cookie.",
                manual: "Paste a full cookie header or the token_v2 value.",
                off: "Notion cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "notion-cookie-source",
                title: "Cookie source",
                subtitle: "Automatically imports the browser session cookie.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: options,
                isVisible: nil,
                onChange: nil),
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
                binding: context.stringBinding(\.notionCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "notion-open-usage",
                        title: "Open Usage Page",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://app.notion.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.notionCookieSource == .manual },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "notion-workspace-id",
                title: "Workspace ID",
                subtitle: "Optional. Defaults to the first Business or Enterprise workspace on the account.",
                kind: .plain,
                placeholder: "00000000-0000-0000-0000-000000000000",
                binding: context.stringBinding(\.notionWorkspaceID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
