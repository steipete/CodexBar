import CodexBarCore
import SwiftUI

struct ProviderSettingsSection<Content: View>: View {
    let title: String
    /// Shown to the right of the title (e.g. usage hints), typically `.caption2` secondary text.
    let titleTrailingNote: String?
    let spacing: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        titleTrailingNote: String? = nil,
        spacing: CGFloat = 12,
        verticalPadding: CGFloat = 10,
        horizontalPadding: CGFloat = 4,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.title = title
        self.titleTrailingNote = titleTrailingNote
        self.spacing = spacing
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.spacing) {
            if let note = self.titleTrailingNote, !note.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.title)
                        .font(.headline)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(self.title)
                    .font(.headline)
            }
            self.content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.verticalPadding)
        .padding(.horizontal, self.horizontalPadding)
    }
}

@MainActor
struct ProviderSettingsToggleRowView: View {
    let toggle: ProviderSettingsToggleDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.toggle.title)
                        .font(.subheadline.weight(.semibold))
                    Text(self.toggle.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                            Button(action.title) {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.picker.title)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                Picker("", selection: self.picker.binding) {
                    ForEach(self.picker.options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if let trailingText = self.picker.trailingText?(), !trailingText.isEmpty {
                    Text(trailingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                }

                Spacer(minLength: 0)
            }

            let subtitle = self.picker.dynamicSubtitle?() ?? self.picker.subtitle
            if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

@MainActor
struct ProviderSettingsFieldRowView: View {
    let field: ProviderSettingsFieldDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let trimmedTitle = self.field.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSubtitle = self.field.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHeader = !trimmedTitle.isEmpty || !trimmedSubtitle.isEmpty

            if hasHeader {
                VStack(alignment: .leading, spacing: 4) {
                    if !trimmedTitle.isEmpty {
                        Text(trimmedTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    if !trimmedSubtitle.isEmpty {
                        Text(trimmedSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            switch self.field.kind {
            case .plain:
                TextField(self.field.placeholder ?? "", text: self.field.binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onTapGesture { self.field.onActivate?() }
            case .secure:
                SecureField(self.field.placeholder ?? "", text: self.field.binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onTapGesture { self.field.onActivate?() }
            }

            let actions = self.field.actions.filter { $0.isVisible?() ?? true }
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button(action.title) {
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

private enum CodexAddAccountMode: String, CaseIterable {
    case oauth
    case apiKey
}

@MainActor
struct ProviderSettingsTokenAccountsRowView: View {
    let descriptor: ProviderSettingsTokenAccountsDescriptor
    @State private var codexAddAccountMode: CodexAddAccountMode = .oauth
    @State private var newLabel: String = ""
    @State private var newToken: String = ""
    @State private var isSigningIn: Bool = false
    @State private var signInProgress: String = ""
    @State private var signInError: String = ""
    /// ID of the token account currently being renamed (nil = none).
    @State private var renamingAccountID: UUID? = nil
    /// Whether the default account tab is being renamed.
    @State private var renamingDefault: Bool = false
    /// Current text inside the active rename field.
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.descriptor.title)
                .font(.subheadline.weight(.semibold))

            if !self.descriptor.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(self.descriptor.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let accounts = self.descriptor.accounts()
            let defaultLabel = self.descriptor.defaultAccountLabel?()
            let hasDefaultTab = defaultLabel != nil
            // activeIndex < 0 means the default account is selected
            let activeIndex = self.descriptor.activeIndex()
            let defaultIsActive = activeIndex < 0 || (accounts.isEmpty && hasDefaultTab)
            let selectedIndex = defaultIsActive ? -1 : min(activeIndex, max(0, accounts.count - 1))

            if !hasDefaultTab && accounts.isEmpty {
                Text("No accounts added yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                self.accountTabsView(
                    defaultLabel: defaultLabel,
                    accounts: accounts,
                    selectedIndex: selectedIndex)
                if self.descriptor.provider == .codex {
                    Text(
                        "Only one account is active at a time. Choose “Menu bar account” under Options below. The house row is your primary ~/.codex sign-in; added rows use a separate OAuth folder or API key. Buy Credits is also under Options.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if self.descriptor.provider == .codex {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add account")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Add account mode", selection: self.$codexAddAccountMode) {
                        Text("OAuth").tag(CodexAddAccountMode.oauth)
                        Text("API key").tag(CodexAddAccountMode.apiKey)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Add account mode")
                    .help("OAuth: browser sign-in. API key: paste an OpenAI key.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if self.descriptor.provider == .codex {
                if self.codexAddAccountMode == .oauth {
                    if let loginAction = self.descriptor.loginAction {
                        self.signInSection(loginAction: loginAction, addAccount: self.descriptor.addAccount)
                    } else {
                        Text("Browser OAuth requires the Codex CLI. You can still add an account with an API key (other tab).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    self.codexAPIKeyAddSection()
                }
            } else if let loginAction = self.descriptor.loginAction {
                self.signInSection(loginAction: loginAction, addAccount: self.descriptor.addAccount)
            } else {
                self.manualAddSection()
            }

            HStack(spacing: 10) {
                Button("Open config file") {
                    self.descriptor.openConfigFile()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Button("Reload") {
                    self.descriptor.reloadFromDisk()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func accountTabsView(
        defaultLabel: String?,
        accounts: [ProviderTokenAccount],
        selectedIndex: Int) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            if let defaultLabel {
                self.defaultAccountTab(label: defaultLabel, isActive: selectedIndex < 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(accounts.enumerated()), id: \.1.id) { index, account in
                self.accountTab(account: account, index: index, isActive: index == selectedIndex)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func menuBarActiveBadge() -> some View {
        Text("Menu bar")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.22)))
            .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder
    private func defaultAccountTab(label: String, isActive: Bool) -> some View {
        let isRenaming = self.renamingDefault && self.descriptor.renameDefaultAccount != nil
        let showCodexHints = self.descriptor.provider == .codex
        let highlightSelection = !showCodexHints
        let rowActive = highlightSelection && isActive
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "house.fill")
                    .foregroundStyle(rowActive ? Color.accentColor : .secondary)
                    .imageScale(.small)
                    .accessibilityLabel("Primary account")
                if isRenaming {
                    TextField("Name", text: self.$renameText)
                        .font(.footnote)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 100, maxWidth: 180)
                        .focused(self.$renameFieldFocused)
                        .onSubmit { self.commitRenameDefault() }
                } else {
                    Group {
                        if showCodexHints {
                            Text(label)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        } else {
                            Button(action: { self.descriptor.setActiveIndex(-1) }) {
                                Text(label)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(rowActive ? Color.accentColor : .primary)
                        }
                    }
                    Spacer(minLength: 8)
                    if rowActive {
                        self.menuBarActiveBadge()
                    }
                    if self.descriptor.renameDefaultAccount != nil {
                        Button(action: {
                            self.renameText = label
                            self.renamingDefault = true
                            self.renamingAccountID = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                self.renameFieldFocused = true
                            }
                        }) {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Rename tab")
                    }
                    if !showCodexHints, !isActive, !isRenaming {
                        Button("Use") {
                            self.descriptor.setActiveIndex(-1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.caption2.weight(.medium))
                        .help("Use this ~/.codex account for the menu bar")
                    }
                }
            }
            if showCodexHints, !isRenaming {
                Text("Primary · ~/.codex on this Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowActive
                    ? Color.accentColor.opacity(0.12)
                    : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(rowActive
                            ? Color.accentColor.opacity(0.45)
                            : Color(NSColor.separatorColor),
                            lineWidth: rowActive ? 1.5 : 1)))
        .onChange(of: self.renameFieldFocused) { _, focused in
            if !focused && self.renamingDefault { self.commitRenameDefault() }
        }
    }

    private func commitRenameDefault() {
        let trimmed = self.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            self.descriptor.renameDefaultAccount?(trimmed)
        }
        self.renamingDefault = false
        self.renameText = ""
    }

    @ViewBuilder
    private func accountTab(account: ProviderTokenAccount, index: Int, isActive: Bool) -> some View {
        let isRenaming = self.renamingAccountID == account.id
        let showCodexHints = self.descriptor.provider == .codex
        let highlightSelection = !showCodexHints
        let rowActive = highlightSelection && isActive
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(rowActive ? Color.accentColor : .secondary)
                    .imageScale(.small)
                    .accessibilityLabel("Added account")
                if isRenaming {
                    TextField("Name", text: self.$renameText)
                        .font(.footnote)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 100, maxWidth: 180)
                        .focused(self.$renameFieldFocused)
                        .onSubmit { self.commitRename(account: account) }
                } else {
                    Group {
                        if showCodexHints {
                            Text(account.displayName)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        } else {
                            Button(action: { self.descriptor.setActiveIndex(index) }) {
                                Text(account.displayName)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(rowActive ? Color.accentColor : .primary)
                        }
                    }
                    Spacer(minLength: 8)
                    if rowActive {
                        self.menuBarActiveBadge()
                    }
                    Button(action: {
                        self.renameText = account.displayName
                        self.renamingAccountID = account.id
                        self.renamingDefault = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.renameFieldFocused = true
                        }
                    }) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Rename tab")
                    Button(action: { self.descriptor.removeAccount(account.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.85))
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Remove account")
                    if !showCodexHints, !isActive, !isRenaming {
                        Button("Use") {
                            self.descriptor.setActiveIndex(index)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.caption2.weight(.medium))
                        .help("Use this account for the menu bar")
                    }
                }
            }
            if showCodexHints, !isRenaming {
                Text("Added account · OAuth folder or API key")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowActive
                    ? Color.accentColor.opacity(0.12)
                    : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(rowActive
                            ? Color.accentColor.opacity(0.45)
                            : Color(NSColor.separatorColor),
                            lineWidth: rowActive ? 1.5 : 1)))
        .onChange(of: self.renameFieldFocused) { _, focused in
            if !focused, self.renamingAccountID == account.id { self.commitRename(account: account) }
        }
    }

    private func commitRename(account: ProviderTokenAccount) {
        let trimmed = self.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            self.descriptor.renameAccount(account.id, trimmed)
        }
        self.renamingAccountID = nil
        self.renameText = ""
    }

    @ViewBuilder
    private func codexAPIKeyAddSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adds an account that sets OPENAI_API_KEY for Codex (stored securely in your config).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Label", text: self.$newLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                SecureField("OpenAI API key", text: self.$newToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                Button("Add") {
                    let label = self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    let token = self.newToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty, !token.isEmpty else { return }
                    self.descriptor.addAccount(label, "apikey:\(token)")
                    self.newLabel = ""
                    self.newToken = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    self.newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func signInSection(
        loginAction: @escaping (
            _ setProgress: @escaping @MainActor (String) -> Void,
            _ addAccount: @escaping @MainActor (String, String) -> Void
        ) async -> Bool,
        addAccount: @escaping (String, String) -> Void) -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            if self.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(self.signInProgress.isEmpty ? "Starting login…" : self.signInProgress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("Sign in to new account") {
                    self.signInError = ""
                    self.isSigningIn = true
                    self.signInProgress = "Opening browser for login…"
                    Task { @MainActor in
                        let success = await loginAction(
                            { @MainActor progress in self.signInProgress = progress },
                            { @MainActor label, token in addAccount(label, token) })
                        self.isSigningIn = false
                        self.signInProgress = ""
                        if !success {
                            self.signInError = "Login failed or was cancelled. Try again."
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !self.signInError.isEmpty {
                Text(self.signInError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func manualAddSection() -> some View {
        HStack(spacing: 8) {
            TextField("Label", text: self.$newLabel)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            if self.descriptor.isSecureToken {
                SecureField(self.descriptor.placeholder, text: self.$newToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
            } else {
                TextField(self.descriptor.placeholder, text: self.$newToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
            }
            Button("Add") {
                let label = self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                let token = self.newToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !token.isEmpty else { return }
                self.descriptor.addAccount(label, token)
                self.newLabel = ""
                self.newToken = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                self.newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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
