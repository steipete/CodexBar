import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AntigravityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .antigravity
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        context.settings.ensureAntigravityAccountsLoaded()

        let accountsBinding = Binding(
            get: {
                let index = context.settings.antigravityCurrentAccountIndex
                let accounts = context.settings.antigravityAccounts?.accounts ?? []
                guard index < accounts.count else { return "" }
                return accounts[index].email
            },
            set: { newValue in
                let accounts = context.settings.antigravityAccounts?.accounts ?? []
                guard let newIndex = accounts.firstIndex(where: { $0.email == newValue }) else { return }
                context.settings.antigravityCurrentAccountIndex = newIndex
                Task {
                    await context.store.refresh()
                }
            })

        let accountOptions = (context.settings.antigravityAccounts?.accounts ?? []).map { account in
            ProviderSettingsPickerOption(id: account.email, title: account.email)
        }

        let accountCount = context.settings.antigravityAccounts?.accounts.count ?? 0

        guard accountCount > 0 else {
            return []
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "antigravity-current-account",
                title: "Account",
                subtitle: "Select Antigravity account to use.",
                binding: accountsBinding,
                options: accountOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    let accounts = context.settings.antigravityAccounts?.accounts ?? []
                    let index = context.settings.antigravityCurrentAccountIndex
                    guard index < accounts.count else { return nil }
                    let account = accounts[index]
                    return "\(accountCount) account\(accountCount == 1 ? "" : "s") stored"
                }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runAntigravityLoginFlow()
        return true
    }
}