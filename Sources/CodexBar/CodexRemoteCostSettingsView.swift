import CodexBarCore
import SwiftUI

/// Shared by the production provider pane and the isolated interactive proof entry point.
@MainActor
struct CodexRemoteCostSettingsView: View {
    @Bindable var store: UsageStore
    @State private var showsDisclosure = false

    static let disclosure = "To deduplicate usage with this Mac, CodexBar temporarily downloads the selected " +
        "server's native Codex logs. Logs may contain conversations and project paths. Temporary raw logs and " +
        "scan files are deleted after calculation. Results stay in memory for this app session and refresh only " +
        "when you click Refresh server statistics. SSH configuration can execute commands you have configured."

    var body: some View {
        @Bindable var remote = self.store.codexRemoteCosts
        Section {
            Toggle("Include one SSH server", isOn: $remote.enabled)
                .accessibilityIdentifier("codex-remote-enabled")
            Text("Native Codex logs only. Saving these settings does not contact the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if remote.enabled {
                if self.store.settings.hidePersonalInfo {
                    SecureField("SSH destination", text: $remote.host)
                        .accessibilityIdentifier("codex-remote-host")
                    SecureField("Remote Codex home", text: $remote.home)
                        .accessibilityIdentifier("codex-remote-home")
                } else {
                    TextField("SSH destination", text: $remote.host, prompt: Text("research-server"))
                        .accessibilityIdentifier("codex-remote-host")
                    TextField("Remote Codex home", text: $remote.home, prompt: Text("~/.codex"))
                        .accessibilityIdentifier("codex-remote-home")
                }
                if self.store.codexRemoteLocalScope != "codex:ambient" {
                    Text("Server statistics require this Mac's shared native history, not a managed account's history.")
                        .font(.caption)
                    Button("Use this Mac’s native history") {
                        self.store.settings.codexLocalSessionCostLedgerEnabled = true
                    }
                }
                HStack {
                    Button("Refresh server statistics") {
                        if remote.consentGranted {
                            self.store.refreshCodexRemoteCosts()
                        } else {
                            self.showsDisclosure = true
                        }
                    }
                    .disabled(remote.isRunning || remote.cleanupRequired || remote.host.isEmpty ||
                        self.store.codexRemoteLocalScope != "codex:ambient")
                    .accessibilityIdentifier("codex-remote-refresh")
                    if remote.isRunning {
                        Button("Cancel") { Task { await remote.cancel() } }
                            .accessibilityIdentifier("codex-remote-cancel")
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if !remote.enabled, remote.isRunning {
                Text("Removing temporary server logs…").font(.caption)
                ProgressView().controlSize(.small)
            }
            // Cleanup problems must remain actionable even when the feature has been disabled.
            if remote.cleanupRequired {
                Text(remote.errorMessage ?? "Temporary server logs need cleanup.")
                    .foregroundStyle(.red)
                Button("Retry temporary log cleanup") { Task { await remote.retryCleanup() } }
                    .disabled(remote.isRunning)
                    .accessibilityIdentifier("codex-remote-cleanup")
            }
            if let presentation = self.store.codexRemoteCostPresentation() {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presentation.lines, id: \.self) { Text($0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("codex-remote-status")
            }
        } header: {
            Text("Manual SSH cost statistics")
        }
        .alert("Temporarily copy server Codex logs?", isPresented: self.$showsDisclosure) {
            Button("Cancel", role: .cancel) {}
            Button("Copy logs and refresh") {
                remote.grantConsent()
                self.store.refreshCodexRemoteCosts()
            }
        } message: {
            Text(Self.disclosure)
        }
    }
}
