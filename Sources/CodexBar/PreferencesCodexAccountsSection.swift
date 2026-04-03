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
    struct LocalProfile: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let detail: String?
        let isActive: Bool
        let isLive: Bool
    }

    let visibleAccounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
    let hasUnreadableManagedAccountStore: Bool
    let isAuthenticatingManagedAccount: Bool
    let authenticatingManagedAccountID: UUID?
    let isAuthenticatingLiveAccount: Bool
    let isPerformingLocalProfileOperation: Bool
    let notice: CodexAccountsSectionNotice?
    let localProfiles: [LocalProfile]
    let hasValidLiveAuth: Bool
    let canSaveCurrentProfile: Bool

    var showsActivePicker: Bool {
        self.visibleAccounts.count > 1
    }

    var singleVisibleAccount: CodexVisibleAccount? {
        self.visibleAccounts.count == 1 ? self.visibleAccounts.first : nil
    }

    var canAddAccount: Bool {
        !self.hasUnreadableManagedAccountStore &&
            !self.isAuthenticatingManagedAccount &&
            !self.isAuthenticatingLiveAccount
    }

    var addAccountTitle: String {
        if self.isAuthenticatingManagedAccount, self.authenticatingManagedAccountID == nil {
            return "Adding Account…"
        }
        return "Add Account"
    }

    var saveCurrentProfileTitle: String {
        self.isPerformingLocalProfileOperation ? "Saving…" : "Save Current Account…"
    }

    var showsSaveCurrentProfileButton: Bool {
        self.canSaveCurrentProfile
    }

    func showsLiveBadge(for account: CodexVisibleAccount) -> Bool {
        self.visibleAccounts.count > 1 && account.isLive && account.storedAccountID == nil
    }

    func canReauthenticate(_ account: CodexVisibleAccount) -> Bool {
        guard account.canReauthenticate else { return false }
        guard self.isAuthenticatingManagedAccount == false else { return false }
        guard self.isAuthenticatingLiveAccount == false else { return false }
        if account.storedAccountID != nil {
            return self.hasUnreadableManagedAccountStore == false
        }
        return true
    }

    func canRemove(_ account: CodexVisibleAccount) -> Bool {
        guard account.canRemove else { return false }
        guard self.isAuthenticatingManagedAccount == false else { return false }
        guard self.isAuthenticatingLiveAccount == false else { return false }
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

    var localProfileActionsDisabled: Bool {
        self.isAuthenticatingManagedAccount || self.isAuthenticatingLiveAccount || self
            .isPerformingLocalProfileOperation
    }
}

@MainActor
struct CodexAccountsSectionView: View {
    let state: CodexAccountsSectionState
    let setActiveVisibleAccount: (String) -> Void
    let reauthenticateAccount: (CodexVisibleAccount) -> Void
    let removeAccount: (CodexVisibleAccount) -> Void
    let addAccount: () -> Void
    let saveCurrentProfile: () -> Void
    let switchLocalProfile: (String) -> Void
    let reloadLocalProfiles: () -> Void
    let openLocalProfilesFolder: () -> Void

    var body: some View {
        ProviderSettingsSection(title: "Accounts") {
            Button(self.state.addAccountTitle) {
                self.addAccount()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.state.canAddAccount == false)
        } content: {
            if let selection = self.activeSelectionBinding {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Active")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                        Picker("", selection: selection) {
                            ForEach(self.state.visibleAccounts) { account in
                                Text(account.email).tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .frame(maxWidth: 300, alignment: .leading)

                        Spacer(minLength: 8)
                    }

                    Text("Choose which Codex account CodexBar should follow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .disabled(self.state.isAuthenticatingManagedAccount || self.state.isAuthenticatingLiveAccount)
            } else if let account = self.state.singleVisibleAccount {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Account")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                        Text(account.email)
                            .font(.subheadline)

                        Spacer(minLength: 8)
                    }
                }
            }

            if self.state.visibleAccounts.isEmpty {
                Text("No Codex accounts detected yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.state.visibleAccounts) { account in
                        CodexAccountsSectionRowView(
                            account: account,
                            showsLiveBadge: self.state.showsLiveBadge(for: account),
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Local Profiles")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if self.state.showsSaveCurrentProfileButton {
                        Button(self.state.saveCurrentProfileTitle) {
                            self.saveCurrentProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(self.state.localProfileActionsDisabled)
                    }
                }

                Text("Save and switch local Codex desktop and CLI accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if self.state.localProfiles.isEmpty {
                    Text(
                        self.state.hasValidLiveAuth
                            ? "No saved local Codex profiles yet. Save the current account to switch back to it later."
                            : "No saved local Codex profiles yet. Log into Codex first to save the current account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(self.state.localProfiles) { profile in
                            CodexLocalProfileRowView(
                                profile: profile,
                                canSwitch: !self.state.localProfileActionsDisabled && !profile.isActive,
                                onSwitch: { self.switchLocalProfile(profile.id) })
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Reload Profiles") {
                        self.reloadLocalProfiles()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .disabled(self.state.localProfileActionsDisabled)

                    Button("Open Profiles Folder") {
                        self.openLocalProfilesFolder()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
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

private struct CodexAccountsSectionRowView: View {
    let account: CodexVisibleAccount
    let showsLiveBadge: Bool
    let reauthenticateTitle: String
    let canReauthenticate: Bool
    let canRemove: Bool
    let onReauthenticate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.account.email)
                    .font(.subheadline.weight(.semibold))
                if self.showsLiveBadge {
                    Text("(Live)")
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

private struct CodexLocalProfileRowView: View {
    let profile: CodexAccountsSectionState.LocalProfile
    let canSwitch: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.profile.title)
                        .font(.subheadline.weight(.semibold))
                    if self.profile.isActive {
                        Text("Active")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                if let subtitle = self.profile.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = self.profile.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if self.profile.isActive {
                EmptyView()
            } else {
                Button("Switch") {
                    self.onSwitch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!self.canSwitch)
            }
        }
    }
}
