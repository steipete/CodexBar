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
        if ZaiSettingsReader.apiToken(environment: context.environment) != nil {
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
                subtitle: "Global uses api.z.ai. China mainland GLM Coding Plan uses open.bigmodel.cn " +
                    "(BigModel keys from bigmodel.cn — not interchangeable with global z.ai keys).",
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
                subtitle: "Required. For China mainland use a BigModel key from open.bigmodel.cn / bigmodel.cn " +
                    "(region BigModel CN). Global uses a z.ai key. Stored in ~/.codexbar/config.json " +
                    "(env: Z_AI_API_KEY, BIGMODEL_API_KEY, ZHIPU_API_KEY).",
                kind: .secure,
                placeholder: "Paste BigModel / z.ai API key…",
                binding: context.stringBinding(\.zaiAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "zai-open-bigmodel-keys",
                        title: "BigModel keys",
                        style: .link,
                        isVisible: { context.settings.zaiAPIRegion == .bigmodelCN },
                        perform: {
                            if let url = URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "zai-open-global-console",
                        title: "z.ai console",
                        style: .link,
                        isVisible: { context.settings.zaiAPIRegion == .global },
                        perform: {
                            if let url = URL(string: "https://z.ai/manage-apikey/apikey") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureZaiAPITokenLoaded() }),
        ]
    }
}
