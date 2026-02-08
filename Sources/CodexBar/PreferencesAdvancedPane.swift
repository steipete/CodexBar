import CodexBarCore
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
                    Text(L10n.tr("settings.advanced.keyboard.section", fallback: "Keyboard shortcut"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .center, spacing: 12) {
                        Text(L10n.tr("settings.advanced.keyboard.open_menu.title", fallback: "Open menu"))
                            .font(.body)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .openMenu)
                    }
                    Text(L10n.tr(
                        "settings.advanced.keyboard.open_menu.subtitle",
                        fallback: "Trigger the menu bar menu from anywhere."))
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
                                Text(L10n.tr("settings.advanced.cli.install", fallback: "Install CLI"))
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
                    Text(L10n.tr(
                        "settings.advanced.cli.install.subtitle",
                        fallback: "Symlink CodexBarCLI to /usr/local/bin and /opt/homebrew/bin as codexbar."))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: L10n.tr("settings.advanced.debug.title", fallback: "Show Debug Settings"),
                        subtitle: L10n.tr(
                            "settings.advanced.debug.subtitle",
                            fallback: "Expose troubleshooting tools in the Debug tab."),
                        binding: self.$settings.debugMenuEnabled)
                    PreferenceToggleRow(
                        title: L10n.tr("settings.advanced.surprise.title", fallback: "Surprise me"),
                        subtitle: L10n.tr(
                            "settings.advanced.surprise.subtitle",
                            fallback: "Check if you like your agents having some fun up there."),
                        binding: self.$settings.randomBlinkEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.advanced.privacy.hide_personal_info.title",
                            fallback: "Hide personal information"),
                        subtitle: L10n.tr(
                            "settings.advanced.privacy.hide_personal_info.subtitle",
                            fallback: "Obscure email addresses in the menu bar and menu UI."),
                        binding: self.$settings.hidePersonalInfo)
                }

                Divider()

                SettingsSection(
                    title: L10n.tr("settings.advanced.keychain.title", fallback: "Keychain access"),
                    caption: L10n.tr(
                        "settings.advanced.keychain.caption",
                        fallback: """
                    Disable all Keychain reads and writes. Browser cookie import is unavailable; paste Cookie \
                    headers manually in Providers.
                    """))
                {
                        PreferenceToggleRow(
                            title: L10n.tr(
                                "settings.advanced.keychain.disable.title",
                                fallback: "Disable Keychain access"),
                            subtitle: L10n.tr(
                                "settings.advanced.keychain.disable.subtitle",
                                fallback: "Prevents any Keychain access while enabled."),
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
            self.cliStatus = L10n.tr(
                "settings.advanced.cli.status.helper_not_found",
                fallback: "CodexBarCLI not found in app bundle.")
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
                let format = L10n.tr(
                    "settings.advanced.cli.status.no_write_access",
                    fallback: "No write access: %@")
                results.append(String(format: format, locale: .current, dir))
                continue
            }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    let format = L10n.tr("settings.advanced.cli.status.installed", fallback: "Installed: %@")
                    results.append(String(format: format, locale: .current, dir))
                } else {
                    let format = L10n.tr("settings.advanced.cli.status.exists", fallback: "Exists: %@")
                    results.append(String(format: format, locale: .current, dir))
                }
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                let format = L10n.tr("settings.advanced.cli.status.installed", fallback: "Installed: %@")
                results.append(String(format: format, locale: .current, dir))
            } catch {
                let format = L10n.tr("settings.advanced.cli.status.failed", fallback: "Failed: %@")
                results.append(String(format: format, locale: .current, dir))
            }
        }

        self.cliStatus = results.isEmpty
            ? L10n.tr("settings.advanced.cli.status.no_writable_dirs", fallback: "No writable bin dirs found.")
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
