import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct NotionProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .notion

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
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.notionCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from Notion.",
                off: "Paste a Cookie header or cURL capture from Notion.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "notion-cookie-source",
                title: "Cookie source",
                subtitle: "Automatically imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "notion-cookie",
                title: "Notion cookie",
                subtitle: "Paste a Cookie header or full cURL capture from app.notion.com.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.notionCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "notion-open-usage",
                        title: "Open Notion AI Usage",
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
