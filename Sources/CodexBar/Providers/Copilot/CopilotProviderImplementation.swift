import AppKit
import CodexBarCore
import CodexBarMacroSupport
import SwiftUI

@ProviderImplementationRegistration
struct CopilotProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .copilot
    let supportsLoginFlow: Bool = true

    func makeFetch(context: ProviderBuildContext) -> @Sendable () async throws -> UsageSnapshot {
        {
            let probe = CopilotStatusProbe()
            let snap = try await probe.fetch()
            return snap.toUsageSnapshot()
        }
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "github api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.copilotAPIToken
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .copilot(context.settings.copilotSettingsSnapshot())
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "copilot-api-token",
                title: "GitHub Login",
                subtitle: "Requires authentication via GitHub Device Flow.",
                kind: .secure,
                placeholder: "Sign in via button below",
                binding: context.stringBinding(\.copilotAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "copilot-login",
                        title: "Sign in with GitHub",
                        style: .bordered,
                        isVisible: { context.settings.copilotAPIToken.isEmpty },
                        perform: {
                            await CopilotLoginFlow.run(settings: context.settings)
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "copilot-relogin",
                        title: "Sign in again",
                        style: .link,
                        isVisible: { !context.settings.copilotAPIToken.isEmpty },
                        perform: {
                            await CopilotLoginFlow.run(settings: context.settings)
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureCopilotAPITokenLoaded() }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await CopilotLoginFlow.run(settings: context.controller.settings)
        return true
    }
}
