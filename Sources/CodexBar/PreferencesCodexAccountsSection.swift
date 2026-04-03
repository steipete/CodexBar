import CodexBarCore
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
    let hasUnreadableManagedAccountStore: Bool
    let isAuthenticatingManagedAccount: Bool
    let authenticatingManagedAccountID: UUID?
    let isAuthenticatingLiveAccount: Bool
    let notice: CodexAccountsSectionNotice?

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
}

struct CodexLocalProfilesSectionState: Equatable {
    struct SettingsProfileRow: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let detail: String?
        let isActive: Bool
    }

    struct MenuProfileRow: Identifiable, Equatable {
        let id: String
        let title: String
        let representedPath: String
        let isActive: Bool
    }

    let settingsProfiles: [SettingsProfileRow]
    let menuProfiles: [MenuProfileRow]
    let hasValidLiveAuth: Bool
    let canSaveCurrentProfile: Bool
    let isPerformingOperation: Bool
    let areActionsDisabled: Bool

    init(
        presentation: CodexLocalProfilesPresentation,
        isPerformingOperation: Bool = false,
        areActionsDisabled: Bool = false)
    {
        let profiles = presentation.profiles
        let displayIdentityCounts = Dictionary(
            grouping: profiles,
            by: { profile in
                let email = profile.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let plan = Self.cleanedPlanName(profile.plan)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                return "\(email)|\(plan)"
            })
            .mapValues(\.count)

        self.settingsProfiles = profiles
            .map { profile in
                let cleanedPlan = Self.cleanedPlanName(profile.plan)
                let email = profile.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identityKey = "\(email?.lowercased() ?? "")|\(cleanedPlan?.lowercased() ?? "")"
                let showsAliasFallback = (displayIdentityCounts[identityKey] ?? 0) > 1 && email != nil

                return SettingsProfileRow(
                    id: profile.fileURL.path,
                    title: email ?? profile.alias,
                    subtitle: cleanedPlan,
                    detail: showsAliasFallback ? "Saved as \(profile.alias)" : nil,
                    isActive: profile.isActiveInCodex)
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        self.menuProfiles = profiles.map { profile in
            MenuProfileRow(
                id: profile.fileURL.path,
                title: "Switch to \(profile.alias)",
                representedPath: profile.fileURL.path,
                isActive: profile.isActiveInCodex)
        }
        self.hasValidLiveAuth = presentation.hasValidLiveAuth
        self.canSaveCurrentProfile = presentation.canSaveCurrentProfile
        self.isPerformingOperation = isPerformingOperation
        self.areActionsDisabled = areActionsDisabled
    }

    var saveCurrentProfileTitle: String {
        self.isPerformingOperation ? "Saving…" : "Save Current Account…"
    }

    var showsSaveCurrentProfileButton: Bool {
        self.canSaveCurrentProfile
    }

    var onboardingText: String? {
        guard self.settingsProfiles.isEmpty else { return nil }
        return "Sign into a Codex account in the Codex app or Codex CLI, then save it here to switch later."
    }

    var settingsEmptyStateText: String {
        self.hasValidLiveAuth ? "No saved profiles yet." : "Log into Codex first to save a profile."
    }

    var menuEmptyStateTitle: String {
        self.hasValidLiveAuth ? "No saved profiles yet" : "Log into Codex first to save a profile"
    }

    private static func cleanedPlanName(_ plan: String?) -> String? {
        guard let plan else { return nil }
        let cleaned = UsageFormatter.cleanPlanName(plan)
        return cleaned.isEmpty ? plan : cleaned
    }
}

@MainActor
struct CodexAccountsSectionView: View {
    let state: CodexAccountsSectionState
    let setActiveVisibleAccount: (String) -> Void
    let reauthenticateAccount: (CodexVisibleAccount) -> Void
    let removeAccount: (CodexVisibleAccount) -> Void
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
                                Text(account.email).tag(account.id)
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

                        Spacer(minLength: 0)
                    }
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
}

@MainActor
struct CodexLocalProfilesSectionView: View {
    private static let helpText =
        """
        1. Sign into a Codex account in the Codex app or Codex CLI.
        2. Choose Save Current Account… in CodexBar.
        3. Repeat for each additional account.
        4. After saving, switch accounts from Local Profiles in Settings or Switch Local Profile in the menu bar.
        """

    let state: CodexLocalProfilesSectionState
    let saveCurrentProfile: () -> Void
    let switchLocalProfile: (String) -> Void
    let reloadLocalProfiles: () -> Void
    let openLocalProfilesFolder: () -> Void

    var body: some View {
        ProviderSettingsSection(title: "Local Profiles") {
            if let onboardingText = self.state.onboardingText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(onboardingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Image(systemName: "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help(Self.helpText)
                }
            }

            if self.state.settingsProfiles.isEmpty {
                Text(self.state.settingsEmptyStateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.state.settingsProfiles) { profile in
                        CodexLocalProfileRowView(
                            profile: profile,
                            canSwitch: !self.state.areActionsDisabled && !profile.isActive,
                            onSwitch: { self.switchLocalProfile(profile.id) })
                    }
                }
            }

            if self.state.showsSaveCurrentProfileButton {
                Button(self.state.saveCurrentProfileTitle) {
                    self.saveCurrentProfile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.state.areActionsDisabled)
            }

            HStack(spacing: 10) {
                Button("Reload Profiles") {
                    self.reloadLocalProfiles()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(self.state.areActionsDisabled)

                Button("Open Profiles Folder") {
                    self.openLocalProfilesFolder()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
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
    let profile: CodexLocalProfilesSectionState.SettingsProfileRow
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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
