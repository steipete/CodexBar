import CodexBarCore
import Foundation
import SwiftUI

struct GrokAccountsSectionNotice: Equatable {
    enum Tone: Equatable {
        case secondary
        case warning
    }

    let text: String
    let tone: Tone
}

struct GrokAccountsSectionState: Equatable {
    let visibleAccounts: [GrokVisibleAccount]
    let activeVisibleAccountID: String?
    let hasUnreadableManagedAccountStore: Bool
    let isAuthenticatingManagedAccount: Bool
    let authenticatingManagedAccountID: UUID?
    let isRemovingManagedAccount: Bool
    let isAuthenticatingLiveAccount: Bool
    let notice: GrokAccountsSectionNotice?

    var showsActivePicker: Bool {
        self.visibleAccounts.count > 1
    }

    var canAddAccount: Bool {
        !self.hasUnreadableManagedAccountStore && !self.hasAccountOperationInFlight
    }

    private var hasAccountOperationInFlight: Bool {
        self.isAuthenticatingManagedAccount || self.isRemovingManagedAccount || self.isAuthenticatingLiveAccount
    }

    var addAccountTitle: String {
        if self.isAuthenticatingManagedAccount, self.authenticatingManagedAccountID == nil {
            return L("Adding Account…")
        }
        return L("Add Account")
    }

    func canReauthenticate(_ account: GrokVisibleAccount) -> Bool {
        guard account.canReauthenticate, !self.hasAccountOperationInFlight else { return false }
        if case .managedAccount = account.selectionSource {
            return !self.hasUnreadableManagedAccountStore
        }
        return true
    }

    func canRemove(_ account: GrokVisibleAccount) -> Bool {
        account.canRemove && self.canAddAccount
    }

    func reauthenticateTitle(for account: GrokVisibleAccount) -> String {
        if case let .managedAccount(accountID) = account.selectionSource,
           self.isAuthenticatingManagedAccount,
           self.authenticatingManagedAccountID == accountID
        {
            return L("Re-authenticating…")
        }
        if account.selectionSource == .liveSystem, self.isAuthenticatingLiveAccount {
            return L("Re-authenticating…")
        }
        return L("Re-auth")
    }
}

@MainActor
struct GrokAccountsSectionView: View {
    let state: GrokAccountsSectionState
    let setActiveVisibleAccount: (String) -> Void
    let reauthenticateAccount: (GrokVisibleAccount) -> Void
    let removeAccount: (GrokVisibleAccount) -> Void
    let addAccount: () -> Void

    var body: some View {
        Section {
            if let selection = self.activeSelectionBinding {
                Picker(L("Active account"), selection: selection) {
                    ForEach(self.state.visibleAccounts) { account in
                        Text(account.displayName).tag(account.id)
                    }
                }
            }

            if !self.state.visibleAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(self.state.visibleAccounts) { account in
                        GrokAccountsSectionRowView(
                            account: account,
                            reauthenticateTitle: self.state.reauthenticateTitle(for: account),
                            canReauthenticate: self.state.canReauthenticate(account),
                            canRemove: self.state.canRemove(account),
                            onReauthenticate: { self.reauthenticateAccount(account) },
                            onRemove: { self.removeAccount(account) })
                    }
                }
            } else {
                Text(L("No Grok account on this Mac."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let notice = self.state.notice {
                Text(notice.text)
                    .font(.footnote)
                    .foregroundStyle(notice.tone == .warning ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(self.state.addAccountTitle) {
                self.addAccount()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.state.canAddAccount == false)
        } header: {
            Text(L("Accounts"))
        }
    }

    private var activeSelectionBinding: Binding<String>? {
        guard self.state.showsActivePicker else { return nil }
        let fallbackID = self.state.activeVisibleAccountID ?? self.state.visibleAccounts.first?.id
        guard let fallbackID else { return nil }
        return Binding(
            get: { self.state.activeVisibleAccountID ?? fallbackID },
            set: { self.setActiveVisibleAccount($0) })
    }
}

private struct GrokAccountsSectionRowView: View {
    let account: GrokVisibleAccount
    let reauthenticateTitle: String
    let canReauthenticate: Bool
    let canRemove: Bool
    let onReauthenticate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.account.displayName)
                        .font(.subheadline.weight(.semibold))
                    if self.account.isLive {
                        Text(L("(System)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(self.reauthenticateTitle) {
                self.onReauthenticate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.canReauthenticate == false)

            if self.account.canRemove {
                Button(L("Remove")) {
                    self.onRemove()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.canRemove == false)
            }
        }
    }
}
