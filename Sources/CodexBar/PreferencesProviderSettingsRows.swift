import CodexBarCore
import SwiftUI

@MainActor
struct ProviderSettingsToggleRowView: View {
    let toggle: ProviderSettingsToggleDescriptor

    var body: some View {
        let isEnabled = self.toggle.isEnabled?() ?? true
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(self.toggle.title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEnabled ? .primary : .tertiary)
                    Text(L(self.toggle.subtitle))
                        .font(.footnote)
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: self.toggle.binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if self.toggle.binding.wrappedValue {
                if let status = self.toggle.statusText?(), !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let actions = self.toggle.actions.filter { $0.isVisible?() ?? true }
                if !actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(actions) { action in
                            Button(L(action.title)) {
                                Task { @MainActor in
                                    await action.perform()
                                }
                            }
                            .applyProviderSettingsButtonStyle(action.style)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .disabled(!isEnabled)
        .onChange(of: self.toggle.binding.wrappedValue) { _, enabled in
            guard let onChange = self.toggle.onChange else { return }
            Task { @MainActor in
                await onChange(enabled)
            }
        }
        .task(id: self.toggle.binding.wrappedValue) {
            guard self.toggle.binding.wrappedValue else { return }
            guard let onAppear = self.toggle.onAppearWhenEnabled else { return }
            await onAppear()
        }
    }
}

@MainActor
struct ProviderSettingsPickerRowView: View {
    let picker: ProviderSettingsPickerDescriptor

    var body: some View {
        let isEnabled = self.picker.isEnabled?() ?? true
        let subtitle = self.picker.dynamicSubtitle?() ?? self.picker.subtitle
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        LabeledContent {
            HStack(spacing: 8) {
                if let trailingText = self.picker.trailingText?(), !trailingText.isEmpty {
                    Text(trailingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Picker("", selection: self.picker.binding) {
                    ForEach(self.picker.options) { option in
                        Text(L(option.title)).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        } label: {
            SettingsRowLabel(
                L(self.picker.title),
                subtitle: trimmedSubtitle.isEmpty ? nil : L(trimmedSubtitle))
        }
        .disabled(!isEnabled)
        .onChange(of: self.picker.binding.wrappedValue) { _, selection in
            guard let onChange = self.picker.onChange else { return }
            Task { @MainActor in
                await onChange(selection)
            }
        }
    }
}

/// Renders a provider settings field descriptor as its own grouped-form section:
/// title becomes the header, subtitle/footer text become the footer, and the
/// placeholder stays inside the field.
@MainActor
struct ProviderSettingsFieldRowView: View {
    let field: ProviderSettingsFieldDescriptor

    var body: some View {
        let trimmedTitle = self.field.title.trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            self.fieldView

            let actions = self.field.actions.filter { $0.isVisible?() ?? true }
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button(L(action.title)) {
                            Task { @MainActor in
                                await action.perform()
                            }
                        }
                        .applyProviderSettingsButtonStyle(action.style)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            if !trimmedTitle.isEmpty {
                Text(L(trimmedTitle))
            }
        } footer: {
            self.footerView
        }
    }

    private var fieldView: some View {
        let prompt = (self.field.placeholder?.isEmpty == false) ? Text(L(self.field.placeholder ?? "")) : nil
        return Group {
            switch self.field.kind {
            case .plain:
                TextField(text: self.field.binding, prompt: prompt) {
                    EmptyView()
                }
            case .secure:
                SecureField(text: self.field.binding, prompt: prompt) {
                    EmptyView()
                }
            }
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .onTapGesture { self.field.onActivate?() }
    }

    @ViewBuilder
    private var footerView: some View {
        let trimmedSubtitle = self.field.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let footer = (self.field.footerText?.isEmpty == false) ? self.field.footerText : nil
        if !trimmedSubtitle.isEmpty || footer != nil {
            VStack(alignment: .leading, spacing: 3) {
                if !trimmedSubtitle.isEmpty {
                    Text(L(trimmedSubtitle))
                }
                if let footer {
                    Text(L(footer))
                }
            }
        }
    }
}

@MainActor
struct ProviderSettingsActionsRowView: View {
    let descriptor: ProviderSettingsActionsDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(self.descriptor.title))
                .font(.subheadline.weight(.semibold))

            if !self.descriptor.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L(self.descriptor.subtitle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let actions = self.descriptor.actions.filter { $0.isVisible?() ?? true }
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button(L(action.title)) {
                            Task { @MainActor in
                                await action.perform()
                            }
                        }
                        .applyProviderSettingsButtonStyle(action.style)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

@MainActor
struct ProviderSettingsTokenAccountsRowView: View {
    struct TeamAccountDraft: Equatable {
        var teamMode: Bool
        var organizationID: String
        var projectID: String

        func normalizedForPersistence() -> Self {
            guard self.teamMode else {
                return Self(teamMode: false, organizationID: "", projectID: "")
            }
            return Self(
                teamMode: true,
                organizationID: self.organizationID.trimmingCharacters(in: .whitespacesAndNewlines),
                projectID: self.projectID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    let descriptor: ProviderSettingsTokenAccountsDescriptor
    @State private var newLabel: String = ""
    @State private var newToken: String = ""
    @State private var newOrgID: String = ""
    @State private var newProjectID: String = ""
    @State private var newTeamMode = false
    @State private var teamDrafts: [UUID: TeamAccountDraft] = [:]

    var body: some View {
        Section {
            let accounts = self.descriptor.accounts()
            if accounts.isEmpty {
                Text(L("No token accounts yet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 10) {
                            Button {
                                self.descriptor.setActiveIndex(index)
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: self.isActive(index: index, accountCount: accounts.count) ?
                                        "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(self.isActive(index: index, accountCount: accounts.count) ?
                                            Color.accentColor : Color.secondary)
                                    Text(account.displayName)
                                        .font(
                                            .footnote.weight(
                                                self.isActive(index: index, accountCount: accounts.count) ?
                                                    .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(L("Remove")) {
                                self.descriptor.removeAccount(account.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if self.descriptor.showsTeamModeControls {
                            self.teamModeEditor(account: account)
                        }
                    }
                }
            }

            if self.descriptor.primaryAddAction == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(text: self.$newLabel, prompt: Text(L("Label"))) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .frame(maxWidth: 160)
                        SecureField(text: self.$newToken, prompt: Text(L(self.descriptor.placeholder))) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        Button(L("Add")) {
                            let label = self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                            let token = self.newToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !label.isEmpty, !token.isEmpty else { return }
                            let orgID = self.descriptor.showsOrganizationField
                                ? self.newOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
                                : ""
                            let teamOrgID = self.newOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
                            let projectID = self.newProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
                            let usageScope = self.descriptor.showsTeamModeControls
                                ? (self.newTeamMode ? "team" : "personal")
                                : nil
                            let accountOrganizationID = if self.newTeamMode {
                                teamOrgID.isEmpty ? nil : teamOrgID
                            } else {
                                orgID.isEmpty ? nil : orgID
                            }
                            let accountWorkspaceID = self.newTeamMode && !projectID.isEmpty ? projectID : nil
                            self.descriptor.addAccount(
                                label,
                                token,
                                usageScope,
                                accountOrganizationID,
                                accountWorkspaceID)
                            self.newLabel = ""
                            self.newToken = ""
                            self.newOrgID = ""
                            self.newProjectID = ""
                            self.newTeamMode = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(Self.isAddDisabled(
                            label: self.newLabel,
                            token: self.newToken,
                            showsTeamModeControls: self.descriptor.showsTeamModeControls,
                            teamMode: self.newTeamMode,
                            teamContext: (organizationID: self.newOrgID, projectID: self.newProjectID)))
                    }
                    if self.descriptor.showsOrganizationField {
                        TextField(text: self.$newOrgID, prompt: Text(L("Org ID (optional)"))) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .help(
                            L("Optional organization ID for accounts linked to multiple Anthropic organizations."))
                    }
                    if self.descriptor.showsTeamModeControls {
                        Toggle(L("Team mode"), isOn: self.$newTeamMode)
                            .toggleStyle(.checkbox)
                            .font(.footnote)
                        if self.newTeamMode {
                            HStack(spacing: 8) {
                                TextField(text: self.$newOrgID, prompt: Text(L("Organization ID"))) {
                                    EmptyView()
                                }
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                                TextField(text: self.$newProjectID, prompt: Text(L("Project ID"))) {
                                    EmptyView()
                                }
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(L("Open token file")) {
                    self.descriptor.openConfigFile()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Button(L("Reload")) {
                    self.descriptor.reloadFromDisk()
                }
                .buttonStyle(.link)
                .controlSize(.small)

                Spacer(minLength: 0)

                if let title = self.descriptor.primaryAddActionTitle,
                   let action = self.descriptor.primaryAddAction
                {
                    Button(L(title)) {
                        Task { @MainActor in
                            await action()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } header: {
            Text(L(self.descriptor.title))
        } footer: {
            if !self.descriptor.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L(self.descriptor.subtitle))
            }
        }
    }

    private func isActive(index: Int, accountCount: Int) -> Bool {
        guard accountCount > 0 else { return false }
        let selectedIndex = min(self.descriptor.activeIndex(), max(0, accountCount - 1))
        return selectedIndex == index
    }

    private func teamModeEditor(account: ProviderTokenAccount) -> some View {
        let draft = self.teamDraft(for: account)
        let original = Self.teamAccountDraft(for: account)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Team mode"), isOn: self.teamModeDraftBinding(account: account))
                .toggleStyle(.checkbox)
                .font(.footnote)
            if draft.teamMode {
                HStack(spacing: 8) {
                    TextField(
                        text: self.organizationIDDraftBinding(account: account),
                        prompt: Text(L("Organization ID")))
                    {
                        EmptyView()
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    TextField(
                        text: self.projectIDDraftBinding(account: account),
                        prompt: Text(L("Project ID")))
                    {
                        EmptyView()
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                }
            }
            Button(L("apply")) {
                self.applyTeamDraft(account: account)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(Self.isTeamDraftApplyDisabled(draft: draft, original: original))
        }
        .padding(.leading, 24)
    }

    private func teamModeDraftBinding(account: ProviderTokenAccount) -> Binding<Bool> {
        Binding(
            get: { self.teamDraft(for: account).teamMode },
            set: { enabled in
                self.updateTeamDraft(account: account) { draft in
                    draft.teamMode = enabled
                }
            })
    }

    private func organizationIDDraftBinding(account: ProviderTokenAccount) -> Binding<String> {
        Binding(
            get: { self.teamDraft(for: account).organizationID },
            set: { value in
                self.updateTeamDraft(account: account) { draft in
                    draft.organizationID = value
                }
            })
    }

    private func projectIDDraftBinding(account: ProviderTokenAccount) -> Binding<String> {
        Binding(
            get: { self.teamDraft(for: account).projectID },
            set: { value in
                self.updateTeamDraft(account: account) { draft in
                    draft.projectID = value
                }
            })
    }

    private func teamDraft(for account: ProviderTokenAccount) -> TeamAccountDraft {
        self.teamDrafts[account.id] ?? Self.teamAccountDraft(for: account)
    }

    private func updateTeamDraft(
        account: ProviderTokenAccount,
        mutate: (inout TeamAccountDraft) -> Void)
    {
        var draft = self.teamDraft(for: account)
        mutate(&draft)
        self.teamDrafts[account.id] = draft
    }

    private func applyTeamDraft(account: ProviderTokenAccount) {
        let draft = self.teamDraft(for: account)
        let original = Self.teamAccountDraft(for: account)
        guard !Self.isTeamDraftApplyDisabled(draft: draft, original: original) else { return }
        let normalized = draft.normalizedForPersistence()
        self.descriptor.updateAccount(
            account.id,
            normalized.teamMode ? "team" : "personal",
            normalized.teamMode ? normalized.organizationID : nil,
            normalized.teamMode ? normalized.projectID : nil)
        self.teamDrafts[account.id] = nil
    }

    static func teamAccountDraft(for account: ProviderTokenAccount) -> TeamAccountDraft {
        let teamMode = account.sanitizedUsageScope?.lowercased() == "team"
        return TeamAccountDraft(
            teamMode: teamMode,
            organizationID: teamMode ? (account.sanitizedOrganizationID ?? "") : "",
            projectID: teamMode ? (account.sanitizedWorkspaceID ?? "") : "")
    }

    static func isTeamDraftApplyDisabled(draft: TeamAccountDraft, original: TeamAccountDraft) -> Bool {
        let draft = draft.normalizedForPersistence()
        let original = original.normalizedForPersistence()
        guard draft != original else { return true }
        guard draft.teamMode else { return false }
        return draft.organizationID.isEmpty || draft.projectID.isEmpty
    }

    static func isAddDisabled(
        label: String,
        token: String,
        showsTeamModeControls: Bool,
        teamMode: Bool,
        teamContext: (organizationID: String, projectID: String)) -> Bool
    {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !token.isEmpty else { return true }
        guard showsTeamModeControls, teamMode else { return false }
        return teamContext.organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            teamContext.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension View {
    @ViewBuilder
    fileprivate func applyProviderSettingsButtonStyle(_ style: ProviderSettingsActionDescriptor.Style) -> some View {
        switch style {
        case .bordered:
            self.buttonStyle(.bordered)
        case .link:
            self.buttonStyle(.link)
        }
    }
}

@MainActor
struct ProviderSettingsOrganizationsRowView: View {
    let descriptor: ProviderSettingsOrganizationsDescriptor
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        Section {
            let entries = self.descriptor.entries()
            if entries.allSatisfy(\.isLocked) {
                Text(L("No organizations loaded. Click Refresh after setting your API key."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Toggle(isOn: Binding(
                        get: { entry.isEnabled },
                        set: { newValue in
                            self.descriptor.onToggle(entry.id, newValue)
                        })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.localizesTitle ? L(entry.title) : entry.title)
                                if let subtitle = entry.subtitle,
                                   !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    Text(entry.localizesSubtitle ? L(subtitle) : subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(entry.isLocked)
                }
            }

            HStack(spacing: 10) {
                Button(L("Refresh organizations")) {
                    Task { @MainActor in
                        self.isRefreshing = true
                        let result = await self.descriptor.onRefresh()
                        self.isRefreshing = false
                        self.errorMessage = result.success ? nil : result.errorMessage
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!self.descriptor.canRefresh() || self.isRefreshing)
                if let errorMessage = self.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(L(self.descriptor.title))
        } footer: {
            if let subtitle = self.descriptor.subtitle,
               !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(L(subtitle))
            }
        }
    }
}
