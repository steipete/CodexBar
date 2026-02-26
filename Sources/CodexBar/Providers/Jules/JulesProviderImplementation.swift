import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct JulesProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .jules
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            let versionText = context.store.version(for: context.provider) ?? "not detected"
            let email = context.store.snapshot(for: .jules)?.identity?.accountEmail ?? ""
            let plan = context.store.snapshot(for: .jules)?.identity?.loginMethod ?? ""
            
            var detail = "\(context.metadata.cliName) \(versionText)"
            if !email.isEmpty {
                detail += " • \(email)"
            }
            if !plan.isEmpty {
                detail += " (\(plan))"
            }
            return detail
        }
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        // Run `jules login` in Terminal.
        // We can't easily automate this since it's an interactive login,
        // so we just show an alert or instructions.
        let alert = NSAlert()
        alert.messageText = "Jules Login"
        alert.informativeText = "To use Jules, you must be logged in via the CLI. Run 'jules login' in your terminal."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return true
    }
}
