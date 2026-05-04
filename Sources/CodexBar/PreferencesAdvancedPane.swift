import CodexBarCore
import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?
    @StateObject private var proxyManager = ProxyManager()

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
                    PreferenceToggleRow(
                        title: "Weekly limit confetti",
                        subtitle: "Play full-screen confetti when weekly usage resets.",
                        binding: self.$settings.confettiOnWeeklyLimitResetsEnabled)
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
                    title: "Local Proxy",
                    caption: """
                    Run a local HTTP proxy to intercept API responses and track token usage. \
                    Set your API client's base URL to http://127.0.0.1:<port>.
                    """) {
                        PreferenceToggleRow(
                            title: "Enable local proxy",
                            subtitle: self.proxyManager.isRunning
                                ? "Running on port \(self.proxyManager.activePort)"
                                : "Not running",
                            binding: Binding(
                                get: { self.settings.proxyEnabled },
                                set: { newValue in
                                    self.settings.proxyEnabled = newValue
                                    if newValue {
                                        self.proxyManager.start(port: self.settings.proxyPort)
                                    } else {
                                        self.proxyManager.stop()
                                    }
                                }))

                        HStack(spacing: 12) {
                            Text("Port")
                                .font(.body)
                            Spacer()
                            TextField("9876", value: self.$settings.proxyPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }

                        if self.proxyManager.isRunning {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Listening on 127.0.0.1:\(self.proxyManager.activePort)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        "http://127.0.0.1:\(self.proxyManager.activePort)",
                                        forType: .string)
                                }
                                .controlSize(.small)
                            }
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
}
