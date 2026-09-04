import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct NousProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .nous

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        NousSettingsReader.credential(environment: context.environment) != nil
    }

    @MainActor
    func settingsActions(context _: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        let status = NousSettingsReader.unavailableMessage(environment: ProcessInfo.processInfo.environment)
            ?? "Reading the Nous Portal login Hermes Agent stored in ~/.hermes/auth.json."
        return [
            ProviderSettingsActionsDescriptor(
                id: "nous-hermes-login",
                title: "Hermes Agent login",
                subtitle: status + " CodexBar never refreshes the token; run `hermes` to renew it. "
                    + "Set NOUS_PORTAL_ACCESS_TOKEN or HERMES_HOME to override.",
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "nous-open-portal",
                        title: "Open Nous Portal",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(NousSettingsReader.defaultPortalBaseURL)
                        }),
                ],
                isVisible: nil),
        ]
    }
}
