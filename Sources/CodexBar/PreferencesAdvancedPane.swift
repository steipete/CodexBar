import AppKit
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
                SettingsSection(contentSpacing: 6) {
                    Text("Refresh cadence")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Picker("", selection: self.$settings.refreshFrequency) {
                        ForEach(RefreshFrequency.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if self.settings.refreshFrequency == .manual {
                        Text("Auto-refresh is off; use the menu's Refresh command.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text("Display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: "Show usage as used",
                        subtitle: "Progress bars fill as you consume quota (instead of showing remaining).",
                        binding: self.$settings.usageBarsShowUsed)
                    PreferenceToggleRow(
                        title: "Show reset time as clock",
                        subtitle: "Display reset times as absolute clock values instead of countdowns.",
                        binding: self.$settings.resetTimesShowAbsolute)
                    PreferenceToggleRow(
                        title: "Show credits + extra usage",
                        subtitle: "Show Codex Credits and Claude Extra usage sections in the menu.",
                        binding: self.$settings.showOptionalCreditsAndExtraUsage)
                    PreferenceToggleRow(
                        title: "Hide personal information",
                        subtitle: "Obscure email addresses in the menu bar and menu UI.",
                        binding: self.$settings.hidePersonalInfo)
                    PreferenceToggleRow(
                        title: "Merge Icons",
                        subtitle: "Use a single menu bar icon with a provider switcher.",
                        binding: self.$settings.mergeIcons)
                    PreferenceToggleRow(
                        title: "Switcher shows icons",
                        subtitle: "Show provider icons in the switcher (otherwise show a weekly progress line).",
                        binding: self.$settings.switcherShowsIcons)
                        .disabled(!self.settings.mergeIcons)
                        .opacity(self.settings.mergeIcons ? 1 : 0.5)
                    PreferenceToggleRow(
                        title: "Menu bar shows percent",
                        subtitle: "Replace critter bars with provider branding icons and a percentage.",
                        binding: self.$settings.menuBarShowsBrandIconWithPercent)
                    PreferenceToggleRow(
                        title: "Surprise me",
                        subtitle: "Check if you like your agents having some fun up there.",
                        binding: self.$settings.randomBlinkEnabled)
                }

                Divider()

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
