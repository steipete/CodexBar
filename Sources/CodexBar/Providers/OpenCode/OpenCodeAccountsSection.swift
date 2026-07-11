import CodexBarCore
import SwiftUI

@MainActor
struct OpenCodeAccountsSectionView: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore
    @State private var workspaceID = ""
    @State private var workspaceLabel = ""
    @State private var statusText: String?

    var body: some View {
        ProviderSettingsSection(title: "OpenCode workspaces") {
            Text("Reuse one OpenCode login across saved workspaces.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Import current login") {
                    Task { @MainActor in
                        await self.importCurrentLogin()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Refresh workspaces") {
                    Task { @MainActor in
                        await self.importCurrentLogin()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if self.settings.opencodeWorkspaceAccounts.accounts.isEmpty {
                Text("No saved workspaces yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.settings.opencodeWorkspaceAccounts.accounts) { account in
                        HStack(spacing: 8) {
                            Button {
                                self.select(accountID: account.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: self.settings.activeOpenCodeWorkspaceAccount?.id == account.id ?
                                        "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(
                                            self.settings.activeOpenCodeWorkspaceAccount?.id == account.id ?
                                                Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.label)
                                            .font(.footnote.weight(.semibold))
                                        if let ownerLabel = account.ownerLabel {
                                            Text(ownerLabel)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button("Remove") {
                                self.settings.removeOpenCodeWorkspace(id: account.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Workspace ID or URL", text: self.$workspaceID)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                TextField("Label", text: self.$workspaceLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                Button("Add") {
                    self.addWorkspace()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let statusText = self.statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func select(accountID: String) {
        guard self.settings.setActiveOpenCodeWorkspace(id: accountID) else { return }
        Task { @MainActor in
            await self.store.refreshProvider(.opencode, allowDisabled: true)
        }
    }

    private func addWorkspace() {
        let id = self.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = self.workspaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenAccountID = self.settings.selectedTokenAccount(for: .opencode)?.id
        let result = self.settings.addOpenCodeWorkspace(
            tokenAccountID: tokenAccountID,
            workspaceID: id,
            label: label.isEmpty ? id : label)
        switch result {
        case .saved:
            self.workspaceID = ""
            self.workspaceLabel = ""
            self.statusText = nil
            Task { @MainActor in
                await self.store.refreshProvider(.opencode, allowDisabled: true)
            }
        case .duplicate:
            self.statusText = "That workspace is already saved."
        case .missingReusableCredential:
            self.statusText = "Import or add an OpenCode login before adding a workspace."
        case .invalidWorkspaceID:
            self.statusText = "Enter a valid OpenCode workspace ID or URL."
        case let .discoveryFailed(message):
            self.statusText = message
        }
    }

    private func importCurrentLogin() async {
        self.statusText = "Importing OpenCode workspaces…"
        do {
            let results = try await self.settings.importOpenCodeWorkspaceAccounts(
                browserDetection: self.store.browserDetection,
                timeout: 60)
            let savedCount = results.count(where: { $0 == .saved })
            self.statusText = savedCount == 0
                ? "OpenCode workspaces are up to date."
                : "Saved \(savedCount) OpenCode workspace\(savedCount == 1 ? "" : "s")."
            await self.store.refreshProvider(.opencode, allowDisabled: true)
        } catch {
            self.statusText = error.localizedDescription
        }
    }
}
