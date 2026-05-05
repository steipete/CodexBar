import Foundation
import SwiftUI

protocol CodexAmbientLoginRunning: Sendable {
    func run(timeout: TimeInterval) async -> CodexLoginRunner.Result
}

struct DefaultCodexAmbientLoginRunner: CodexAmbientLoginRunning {
    func run(timeout: TimeInterval) async -> CodexLoginRunner.Result {
        await CodexLoginRunner.run(timeout: timeout)
    }
}

struct CodexAccountsSectionNotice: Equatable {
    enum Tone: Equatable {
        case secondary
        case warning
    }

    let text: String
    let tone: Tone
}

struct CodexAccountsSectionState: Equatable {
    let visibleAccounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
    let liveVisibleAccountID: String?
    let hasUnreadableManagedAccountStore: Bool
    let isAuthenticatingManagedAccount: Bool
    let authenticatingManagedAccountID: UUID?
    let isRemovingManagedAccount: Bool
    let isAuthenticatingLiveAccount: Bool
    let isPromotingSystemAccount: Bool
    let notice: CodexAccountsSectionNotice?

    var showsActivePicker: Bool {
        self.visibleAccounts.count > 1
    }

    var singleVisibleAccount: CodexVisibleAccount? {
        self.visibleAccounts.count == 1 ? self.visibleAccounts.first : nil
    }

    var systemVisibleAccount: CodexVisibleAccount? {
        guard let liveVisibleAccountID else { return nil }
        return self.visibleAccounts.first { $0.id == liveVisibleAccountID }
    }

    var showsSystemPicker: Bool {
        self.visibleAccounts.count > 1 || (self.liveVisibleAccountID == nil && !self.visibleAccounts.isEmpty)
    }

    var systemDisplayName: String {
        self.systemVisibleAccount?.displayName ?? "No system account"
    }

    var canAddAccount: Bool {
        !self.hasUnreadableManagedAccountStore &&
            !self.isAuthenticatingManagedAccount &&
            !self.isRemovingManagedAccount &&
            !self.isAuthenticatingLiveAccount &&
            !self.isPromotingSystemAccount
    }

    var addAccountTitle: String {
        if self.isAuthenticatingManagedAccount, self.authenticatingManagedAccountID == nil {
            return "Adding Account…"
        }
        return "Add Account"
    }

    func showsLiveBadge(for account: CodexVisibleAccount) -> Bool {
        account.isLive
    }

    var isSystemSelectionDisabled: Bool {
        self.hasUnreadableManagedAccountStore ||
            self.isAuthenticatingManagedAccount ||
            self.isRemovingManagedAccount ||
            self.isAuthenticatingLiveAccount ||
            self.isPromotingSystemAccount
    }

    func canPromoteToSystem(_ account: CodexVisibleAccount) -> Bool {
        guard self.isSystemSelectionDisabled == false else { return false }
        guard account.id != self.liveVisibleAccountID else { return false }
        return account.storedAccountID != nil
    }

    func canReauthenticate(_ account: CodexVisibleAccount) -> Bool {
        guard account.canReauthenticate else { return false }
        guard self.isAuthenticatingManagedAccount == false else { return false }
        guard self.isRemovingManagedAccount == false else { return false }
        guard self.isAuthenticatingLiveAccount == false else { return false }
        guard self.isPromotingSystemAccount == false else { return false }
        if account.storedAccountID != nil {
            return self.hasUnreadableManagedAccountStore == false
        }
        return true
    }

    func canRemove(_ account: CodexVisibleAccount) -> Bool {
        guard account.canRemove else { return false }
        guard self.isAuthenticatingManagedAccount == false else { return false }
        guard self.isRemovingManagedAccount == false else { return false }
        guard self.isAuthenticatingLiveAccount == false else { return false }
        guard self.isPromotingSystemAccount == false else { return false }
        return self.hasUnreadableManagedAccountStore == false
    }

    func reauthenticateTitle(for account: CodexVisibleAccount) -> String {
        if let accountID = account.storedAccountID,
           self.isAuthenticatingManagedAccount,
           self.authenticatingManagedAccountID == accountID
        {
            return "Re-authenticating…"
        }
        if account.storedAccountID == nil, self.isAuthenticatingLiveAccount {
            return "Re-authenticating…"
        }
        return "Re-auth"
    }
}

@MainActor
struct CodexAccountsSectionView: View {
    let state: CodexAccountsSectionState
    let setActiveVisibleAccount: (String) -> Void
    let reauthenticateAccount: (CodexVisibleAccount) -> Void
    let removeAccount: (CodexVisibleAccount) -> Void
    let requestSystemVisibleAccount: (String) -> Void
    let addAccount: () -> Void

    var body: some View {
        ProviderSettingsSection(title: "Accounts") {
            if let selection = self.activeSelectionBinding {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Active")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                        Picker("", selection: selection) {
                            ForEach(self.state.visibleAccounts) { account in
                                Text(account.displayName).tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)

                        Spacer(minLength: 0)
                    }

                    Text("Choose which Codex account CodexBar should follow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    self.systemRow(selection: self.systemSelectionBinding)
                }
                .disabled(
                    self.state.isAuthenticatingManagedAccount ||
                        self.state.isRemovingManagedAccount ||
                        self.state.isAuthenticatingLiveAccount ||
                        self.state.isPromotingSystemAccount)
            } else if let account = self.state.singleVisibleAccount {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Account")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                        Text(account.displayName)
                            .font(.subheadline)

                        Spacer(minLength: 0)
                    }

                    self.systemRow(selection: nil)
                }
            }

            if self.state.visibleAccounts.isEmpty {
                Text("No Codex accounts detected yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(self.state.visibleAccounts) { account in
                        CodexAccountsSectionRowView(
                            account: account,
                            showsSystemBadge: self.state.showsLiveBadge(for: account),
                            reauthenticateTitle: self.state.reauthenticateTitle(for: account),
                            canReauthenticate: self.state.canReauthenticate(account),
                            canRemove: self.state.canRemove(account),
                            onReauthenticate: { self.reauthenticateAccount(account) },
                            onRemove: { self.removeAccount(account) })
                    }
                }
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

    private var systemSelectionBinding: Binding<String>? {
        guard self.state.showsSystemPicker else { return nil }
        guard let liveVisibleAccountID = self.state.liveVisibleAccountID else { return nil }
        return Binding(
            get: { self.state.liveVisibleAccountID ?? liveVisibleAccountID },
            set: { self.requestSystemVisibleAccount($0) })
    }

    @ViewBuilder
    private func systemRow(selection: Binding<String>?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("System")
                .font(.subheadline.weight(.semibold))
                .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

            if let selection {
                Picker("", selection: selection) {
                    ForEach(self.state.visibleAccounts) { account in
                        Text(account.displayName)
                            .tag(account.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(self.state.isSystemSelectionDisabled)
            } else if self.state.showsSystemPicker {
                Menu {
                    ForEach(self.state.visibleAccounts) { account in
                        Button(account.displayName) {
                            self.requestSystemVisibleAccount(account.id)
                        }
                        .disabled(self.state.canPromoteToSystem(account) == false)
                    }
                } label: {
                    Text(self.state.systemDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(self.state.isSystemSelectionDisabled)
            } else {
                Text(self.state.systemDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(self.state.systemVisibleAccount == nil ? .secondary : .primary)
            }

            Spacer(minLength: 0)
        }

        Text("The default Codex account on this Mac.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct CodexAccountsSectionRowView: View {
    let account: CodexVisibleAccount
    let showsSystemBadge: Bool
    let reauthenticateTitle: String
    let canReauthenticate: Bool
    let canRemove: Bool
    let onReauthenticate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.account.displayName)
                    .font(.subheadline.weight(.semibold))
                if self.showsSystemBadge {
                    Text("(System)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if self.account.canReauthenticate {
                Button(self.reauthenticateTitle) {
                    self.onReauthenticate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.canReauthenticate == false)
            }

            if self.account.canRemove {
                Button("Remove") {
                    self.onRemove()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.canRemove == false)
            }
        }
    }
}
