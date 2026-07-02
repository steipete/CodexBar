import CodexBarCore
import KeyboardShortcuts
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var isInstallingCLI = false
    @State private var cliStatus: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard(title: L("section_automation"), systemImage: "bolt.horizontal.circle") {
                    PreferenceSwitchRow(
                        title: L("refresh_on_open_title"),
                        subtitle: L("refresh_on_open_subtitle"),
                        binding: self.$settings.refreshAllProvidersOnMenuOpen)

                    SettingsCardDivider()

                    PreferenceSwitchRow(
                        title: L("check_provider_status_title"),
                        subtitle: L("check_provider_status_subtitle"),
                        binding: self.$settings.statusChecksEnabled)
                }

                SettingsCard(title: L("section_usage"), systemImage: "chart.bar.xaxis") {
                    CostSummarySettingsGroup(settings: self.settings, store: self.store)
                }

                SettingsCard(title: L("section_keyboard_shortcut"), systemImage: "command") {
                    PreferenceControlRow(
                        title: L("open_menu_shortcut_title"),
                        subtitle: L("open_menu_shortcut_subtitle"))
                    {
                        OpenMenuShortcutRecorder()
                    }
                    .settingsCardRow()
                }

                SettingsCard(title: L("install_cli"), systemImage: "terminal") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("install_cli_subtitle"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let status = self.cliStatus {
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 16)

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
                    }
                    .settingsCardRow()
                }

                SettingsCard(title: L("section_system"), systemImage: "gearshape.2") {
                    PreferenceSwitchRow(
                        title: L("show_debug_settings_title"),
                        subtitle: L("show_debug_settings_subtitle"),
                        binding: self.$settings.debugMenuEnabled)

                    SettingsCardDivider()

                    PreferenceSwitchRow(
                        title: L("hide_personal_info_title"),
                        subtitle: L("hide_personal_info_subtitle"),
                        binding: self.$settings.hidePersonalInfo)

                    SettingsCardDivider()

                    PreferenceSwitchRow(
                        title: L("show_provider_storage_usage_title"),
                        subtitle: L("show_provider_storage_usage_subtitle"),
                        binding: self.$settings.providerStorageFootprintsEnabled)
                }

                SettingsCard(title: L("section_loading_animations"), systemImage: "sparkles") {
                    PreferenceSwitchRow(
                        title: L("surprise_me_title"),
                        subtitle: L("surprise_me_subtitle"),
                        binding: self.$settings.randomBlinkEnabled)

                    SettingsCardDivider()

                    PreferenceSwitchRow(
                        title: L("session_limit_confetti_title"),
                        subtitle: L("session_limit_confetti_subtitle"),
                        binding: self.$settings.confettiOnSessionLimitResetsEnabled)

                    SettingsCardDivider()

                    PreferenceSwitchRow(
                        title: L("weekly_limit_confetti_title"),
                        subtitle: L("weekly_limit_confetti_subtitle"),
                        binding: self.$settings.confettiOnWeeklyLimitResetsEnabled)
                }

                SettingsCard(
                    title: L("section_keychain_access"),
                    systemImage: "key",
                    caption: L("keychain_access_caption"))
                {
                    PreferenceSwitchRow(
                        title: L("disable_keychain_access_title"),
                        subtitle: L("disable_keychain_access_subtitle"),
                        binding: self.$settings.debugDisableKeychainAccess)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }
}

@MainActor
struct OpenMenuShortcutRecorder: NSViewRepresentable {
    static let preferredWidth: CGFloat = 170

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: .openMenu)
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
        nsView.shortcutName = .openMenu
    }

    func sizeThatFits(
        _: ProposedViewSize,
        nsView: KeyboardShortcuts.RecorderCocoa,
        context: Context)
        -> CGSize?
    {
        Self.fittedSize(intrinsicHeight: nsView.intrinsicContentSize.height)
    }

    static func fittedSize(intrinsicHeight: CGFloat) -> CGSize {
        CGSize(width: self.preferredWidth, height: intrinsicHeight)
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
            ? L("no_writable_bin_dirs")
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
