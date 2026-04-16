import CodexBarCore
import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?
    @State private var auditStatus: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 8) {
                    Text("Keyboard shortcut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .center, spacing: 12) {
                        Text("Open menu")
                            .font(.body)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .openMenu)
                    }
                    Text("Trigger the menu bar menu from anywhere.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await self.installCLI() }
                        } label: {
                            if self.isInstallingCLI {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Install CLI")
                            }
                        }
                        .disabled(self.isInstallingCLI)

                        if let status = self.cliStatus {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Text("Symlink CodexBarCLI to /usr/local/bin and /opt/homebrew/bin as codexbar.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: "Show Debug Settings",
                        subtitle: "Expose troubleshooting tools in the Debug tab.",
                        binding: self.$settings.debugMenuEnabled)
                    PreferenceToggleRow(
                        title: "Surprise me",
                        subtitle: "Check if you like your agents having some fun up there.",
                        binding: self.$settings.randomBlinkEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: "Hide personal information",
                        subtitle: "Obscure email addresses in the menu bar and menu UI.",
                        binding: self.$settings.hidePersonalInfo)
                }

                Divider()

                SettingsSection(
                    title: "Keychain access",
                    caption: """
                    Disable all Keychain reads and writes. Browser cookie import is unavailable; paste Cookie \
                    headers manually in Providers.
                    """) {
                        PreferenceToggleRow(
                            title: "Disable Keychain access",
                            subtitle: "Prevents any Keychain access while enabled.",
                            binding: self.$settings.debugDisableKeychainAccess)
                    }

                Divider()

                SettingsSection(
                    title: "Governance Summary",
                    caption: """
                    Keep a local summary of sensitive actions for troubleshooting. This is observability \
                    only and does not block or alter behavior.
                    """) {
                        PreferenceToggleRow(
                            title: "Enable Governance Summary",
                            subtitle: "Write a local Markdown summary of sensitive actions on this Mac.",
                            binding: self.$settings.governanceAuditModeEnabled)

                        DisclosureGroup("Customize recorded event types") {
                            VStack(alignment: .leading, spacing: 10) {
                                PreferenceToggleRow(
                                    title: "Audit network requests",
                                    subtitle: "Record request metadata and elevated-risk network flows without storing request secrets.",
                                    binding: self.$settings.governanceAuditNetworkRequestsEnabled)
                                PreferenceToggleRow(
                                    title: "Audit command execution",
                                    subtitle: "Record spawned commands and high-risk subprocess flows.",
                                    binding: self.$settings.governanceAuditCommandExecutionEnabled)
                                PreferenceToggleRow(
                                    title: "Audit secret access",
                                    subtitle: "Record keychain and auth-material access without storing accessed values.",
                                    binding: self.$settings.governanceAuditSecretAccessEnabled)
                            }
                            .padding(.top, 8)
                        }
                        .font(.footnote)

                        Text("By default, enabling the summary records network, command, and secret events.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 12) {
                            Button {
                                self.revealAuditLogFolder()
                            } label: {
                                Label("Reveal log folder", systemImage: "folder")
                            }
                            .controlSize(.small)

                            Button(role: .destructive) {
                                self.clearAuditLogs()
                            } label: {
                                Label("Clear governance summary", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }

                        Text(
                            """
                            Governance summaries stay on this Mac in \(Self.auditLogDisplayPath). CodexBar groups \
                            sensitive actions into a Markdown summary and keeps technical debug logging in \
                            CodexBar.log.
                            """)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)

                        if let auditStatus = self.auditStatus {
                            Text(auditStatus)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

extension AdvancedPane {
    private static var auditLogDisplayPath: String {
        let path = AuditLogger.summaryFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func installCLI() async {
        if self.isInstallingCLI { return }
        self.isInstallingCLI = true
        defer { self.isInstallingCLI = false }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        let fm = FileManager.default
        guard fm.fileExists(atPath: helperURL.path) else {
            self.cliStatus = "CodexBarCLI not found in app bundle."
            return
        }

        let destinations = [
            "/usr/local/bin/codexbar",
            "/opt/homebrew/bin/codexbar",
        ]

        var results: [String] = []
        for dest in destinations {
            let dir = (dest as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: dir) else { continue }
            guard fm.isWritableFile(atPath: dir) else {
                results.append("No write access: \(dir)")
                continue
            }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    results.append("Installed: \(dir)")
                } else {
                    results.append("Exists: \(dir)")
                }
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                results.append("Installed: \(dir)")
            } catch {
                results.append("Failed: \(dir)")
            }
        }

        self.cliStatus = results.isEmpty
            ? "No writable bin dirs found."
            : results.joined(separator: " · ")
    }

    private static func isLink(atPath path: String, pointingTo destination: String) -> Bool {
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: dir))
            .standardizedFileURL
            .path
        return resolved == destination
    }

    private func revealAuditLogFolder() {
        do {
            let url = try AuditLogger.ensureLogDirectoryExists()
            NSWorkspace.shared.open(url)
            self.auditStatus = "Opened \(url.path)."
        } catch {
            self.auditStatus = "Failed to open log folder."
        }
    }

    private func clearAuditLogs() {
        do {
            try AuditLogger.clearLogs()
            self.auditStatus = "Cleared governance audit summary."
        } catch {
            self.auditStatus = "Failed to clear governance audit summary."
        }
    }
}
