import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ZaiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.zaiAPIToken
        _ = settings.zaiAPIRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .zai(context.settings.zaiSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ZaiSettingsReader.apiToken(
            for: context.settings.zaiAPIRegion,
            environment: context.environment) != nil
        {
            return true
        }
        context.settings.ensureZaiAPITokenLoaded()
        return !context.settings.zaiAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = Binding(
            get: { context.settings.zaiAPIRegion.rawValue },
            set: { raw in
                context.settings.zaiAPIRegion = ZaiAPIRegion(rawValue: raw) ?? .global
            })
        let options = ZaiAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "zai-api-region",
                title: "API region",
                subtitle: "Global uses api.z.ai. China mainland uses open.bigmodel.cn with a BigModel/GLM key; " +
                    "the two key families are not interchangeable.",
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "zai-api-key",
                title: "API key",
                subtitle: "Use a key issued for the selected region. China also reads BIGMODEL_API_KEY, " +
                    "ZHIPU_API_KEY, GLM_API_KEY, or ~/.coding-relay/glm-api-key.",
                kind: .secure,
                placeholder: "Paste z.ai / GLM API key…",
                binding: context.stringBinding(\.zaiAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "zai-open-api-keys",
                        title: "Open regional API keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            let url = context.settings.zaiAPIRegion == .bigmodelCN
                                ? URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")
                                : URL(string: "https://z.ai/manage-apikey/apikey")
                            if let url {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureZaiAPITokenLoaded() }),
        ]
    }
}
