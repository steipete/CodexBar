import CodexBarCore
import Foundation
import SwiftUI

struct GeminiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gemini
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        guard Self.showsAntigravityMigrationAction(context: context) else { return [] }
        return [
            ProviderSettingsActionsDescriptor(
                id: "gemini-antigravity-migration",
                title: "Gemini CLI migration",
                subtitle: GeminiConsumerTierMigration.deprecationError,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "gemini-enable-antigravity",
                        title: "Enable Antigravity provider",
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            context.settings.setProviderEnabled(
                                provider: .antigravity,
                                metadata: ProviderDescriptorRegistry.descriptor(for: .antigravity).metadata,
                                enabled: true)
                            await context.store.refreshProvider(.antigravity, allowDisabled: true)
                        }),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGeminiLoginFlow()
        return false
    }

    @MainActor
    private static func showsAntigravityMigrationAction(context: ProviderSettingsContext) -> Bool {
        context.store.geminiObservedConsumerTierDeprecation
    }
}
