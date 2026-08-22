import CodexBarCore
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        Task { await self.installCLI() }
                    } label: {
                        if self.isInstallingCLI {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("install_cli"))
                        }
                    }
                    .disabled(self.isInstallingCLI)
                } label: {
                    SettingsRowLabel(L("install_cli"), subtitle: L("install_cli_subtitle"))
                }
            } header: {
                Text(L("section_command_line"))
            } footer: {
                if let status = self.cliStatus {
                    SettingsSectionFooter(status)
                }
            }

            Section {
                Toggle(isOn: self.$settings.hidePersonalInfo) {
                    SettingsRowLabel(L("hide_personal_info_title"), subtitle: L("hide_personal_info_subtitle"))
                }

                Toggle(isOn: self.$settings.debugDisableKeychainAccess) {
                    SettingsRowLabel(
                        L("disable_keychain_access_title"),
                        subtitle: L("disable_keychain_access_subtitle"))
                }
            } header: {
                Text(L("section_privacy"))
            } footer: {
                SettingsSectionFooter(L("keychain_access_caption"))
            }

            Section {
                Toggle(isOn: self.$settings.providerStorageFootprintsEnabled) {
                    SettingsRowLabel(
                        L("show_provider_storage_usage_title"),
                        subtitle: L("show_provider_storage_usage_subtitle"))
                }

                Toggle(isOn: self.$settings.debugMenuEnabled) {
                    SettingsRowLabel(L("show_debug_settings_title"), subtitle: L("show_debug_settings_subtitle"))
                }
            } header: {
                Text(L("section_diagnostics"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
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
            self.cliStatus = L("cli_not_found")
            return
        }

        let destinations = [
            "/usr/local/bin/codexbar",
            "/opt/homebrew/bin/codexbar",
        ]

        var installed: [String] = []
        var failures: [String] = []
        for dest in destinations {
            let dir = (dest as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: dir) else { continue }
            guard fm.isWritableFile(atPath: dir) else {
                failures.append("No write access: \(dir)")
                continue
            }

            if fm.fileExists(atPath: dest) {
                if Self.isLink(atPath: dest, pointingTo: helperURL.path) {
                    installed.append("Installed: \(dir)")
                } else {
                    failures.append("Exists: \(dir)")
                }
                continue
            }

            do {
                try fm.createSymbolicLink(atPath: dest, withDestinationPath: helperURL.path)
                installed.append("Installed: \(dir)")
            } catch {
                failures.append("Failed: \(dir)")
            }
        }

        self.cliStatus = Self.cliInstallStatus(installed: installed, failures: failures)
    }

    private static func isLink(atPath path: String, pointingTo destination: String) -> Bool {
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: dir))
            .standardizedFileURL
            .path
        return resolved == destination
    }

    static func cliInstallStatus(installed: [String], failures: [String]) -> String {
        if installed.isEmpty == false {
            return installed.joined(separator: " · ")
        }
        if failures.isEmpty == false {
            return failures.joined(separator: " · ")
        }
        return L("no_writable_bin_dirs")
    }
}
