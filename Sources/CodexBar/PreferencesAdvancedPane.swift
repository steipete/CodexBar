import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 8) {
                    Text(AppStrings.tr("Keyboard shortcut"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .center, spacing: 12) {
                        Text(AppStrings.tr("Open menu"))
                            .font(.body)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .openMenu)
                    }
                    Text(AppStrings.tr("Trigger the menu bar menu from anywhere."))
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
                                Text(AppStrings.tr("Install CLI"))
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
                    Text(AppStrings.tr("Symlink CodexBarCLI to /usr/local/bin and /opt/homebrew/bin as codexbar."))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: AppStrings.tr("Show Debug Settings"),
                        subtitle: AppStrings.tr("Expose troubleshooting tools in the Debug tab."),
                        binding: self.$settings.debugMenuEnabled)
                    PreferenceToggleRow(
                        title: AppStrings.tr("Surprise me"),
                        subtitle: AppStrings.tr("Check if you like your agents having some fun up there."),
                        binding: self.$settings.randomBlinkEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: AppStrings.tr("Hide personal information"),
                        subtitle: AppStrings.tr("Obscure email addresses in the menu bar and menu UI."),
                        binding: self.$settings.hidePersonalInfo)
                }

                Divider()

                SettingsSection(
                    title: AppStrings.tr("Keychain access"),
                    caption: AppStrings.tr(
                        "Disable all Keychain reads and writes. Browser cookie import is unavailable; " +
                            "paste Cookie headers manually in Providers."))
                {
                    PreferenceToggleRow(
                        title: AppStrings.tr("Disable Keychain access"),
                        subtitle: AppStrings.tr("Prevents any Keychain access while enabled."),
                        binding: self.$settings.debugDisableKeychainAccess)
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
            self.cliStatus = AppStrings.tr("CodexBarCLI not found in app bundle.")
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
                results.append(AppStrings.fmt("No write access: %@", dir))
                continue
            }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    results.append(AppStrings.fmt("Installed: %@", dir))
                } else {
                    results.append(AppStrings.fmt("Exists: %@", dir))
                }
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                results.append(AppStrings.fmt("Installed: %@", dir))
            } catch {
                results.append(AppStrings.fmt("Failed: %@", dir))
            }
        }

        self.cliStatus = results.isEmpty
            ? AppStrings.tr("No writable bin dirs found.")
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
