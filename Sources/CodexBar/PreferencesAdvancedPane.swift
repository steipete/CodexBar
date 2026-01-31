import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?
    @State private var keychainStatus: KeychainSetupHelper.AccessStatus = .notFound
    @State private var showingKeychainInstructions = false

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

                // Chrome Safe Storage setup section
                if !self.settings.debugDisableKeychainAccess {
                    Divider()

                    SettingsSection(
                        title: "Browser cookie access",
                        caption: """
                        Chrome-based browsers encrypt cookies with a key stored in Keychain. \
                        CodexBar needs "Always Allow" access to read cookies without prompts.
                        """) {
                            self.keychainSetupView
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            self.checkKeychainStatus()
        }
        .sheet(isPresented: self.$showingKeychainInstructions) {
            KeychainSetupInstructionsView(isPresented: self.$showingKeychainInstructions) {
                self.checkKeychainStatus()
            }
        }
    }

    @ViewBuilder
    private var keychainSetupView: some View {
        HStack(spacing: 12) {
            switch self.keychainStatus {
            case .allowed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Chrome Safe Storage: Access granted")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .needsSetup:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Chrome Safe Storage: Setup needed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fix Now") {
                    self.showingKeychainInstructions = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .notFound:
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("No Chrome-based browser detected")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

            case .keychainDisabled:
                Image(systemName: "lock.slash")
                    .foregroundColor(.secondary)
                Text("Keychain access is disabled")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }

        Button("Check Status") {
            self.checkKeychainStatus()
        }
        .buttonStyle(.link)
        .controlSize(.small)
    }

    private func checkKeychainStatus() {
        self.keychainStatus = KeychainSetupHelper.checkChromeSafeStorageAccess()
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

// MARK: - Keychain Setup Instructions Sheet

@MainActor
struct KeychainSetupInstructionsView: View {
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fix Keychain Prompts")
                        .font(.headline)
                    Text("One-time setup to stop repeated permission dialogs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 12) {
                Text("Follow these steps:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(Array(KeychainSetupHelper.setupInstructions.enumerated()), id: \.offset) { _, instruction in
                    HStack(alignment: .top, spacing: 8) {
                        Text(instruction)
                            .font(.callout)
                    }
                }
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Open Keychain Access") {
                    KeychainSetupHelper.openKeychainAccessForSetup()
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Done") {
                    self.onComplete()
                    self.isPresented = false
                }
            }

            // Tip
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Tip: You may need to unlock the keychain with your Mac password first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
    }
}
