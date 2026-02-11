import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct AboutPane: View {
    let updater: UpdaterProviding
    @State private var iconHover = false
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled: Bool = true
    @AppStorage(UpdateChannel.userDefaultsKey)
    private var updateChannelRaw: String = UpdateChannel.defaultChannel.rawValue
    @State private var didLoadUpdaterState = false

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var buildTimestamp: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let image = NSApplication.shared.applicationIconImage {
                Button(action: self.openProjectHome) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .cornerRadius(16)
                        .scaleEffect(self.iconHover ? 1.05 : 1.0)
                        .shadow(color: self.iconHover ? .accentColor.opacity(0.25) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        self.iconHover = hovering
                    }
                }
            }

            VStack(spacing: 2) {
                Text("CodexBar")
                    .font(.title3).bold()
                Text(String(
                    format: L10n.tr("settings.about.version", fallback: "Version %@"),
                    locale: .current,
                    self.versionString))
                    .foregroundStyle(.secondary)
                if let buildTimestamp {
                    Text(String(
                        format: L10n.tr("settings.about.build", fallback: "Built %@"),
                        locale: .current,
                        buildTimestamp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.tr(
                    "settings.about.tagline",
                    fallback: "May your tokens never run out—keep agent limits in view."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .center, spacing: 10) {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: L10n.tr("settings.about.link.github", fallback: "GitHub"),
                    url: "https://github.com/steipete/CodexBar")
                AboutLinkRow(
                    icon: "globe",
                    title: L10n.tr("settings.about.link.website", fallback: "Website"),
                    url: "https://steipete.me")
                AboutLinkRow(
                    icon: "bird",
                    title: L10n.tr("settings.about.link.twitter", fallback: "Twitter"),
                    url: "https://twitter.com/steipete")
                AboutLinkRow(
                    icon: "envelope",
                    title: L10n.tr("settings.about.link.email", fallback: "Email"),
                    url: "mailto:peter@steipete.me")
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Divider()

            if self.updater.isAvailable {
                VStack(spacing: 10) {
                    Toggle(
                        L10n.tr("settings.about.updates.auto_check", fallback: "Check for updates automatically"),
                        isOn: self.$autoUpdateEnabled)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .center)
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            Text(L10n.tr("settings.about.updates.channel", fallback: "Update Channel"))
                            Spacer()
                            Picker("", selection: self.updateChannelBinding) {
                                ForEach(UpdateChannel.allCases) { channel in
                                    Text(channel.displayName).tag(channel)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .frame(maxWidth: 280)
                        Text(self.updateChannel.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    Button(L10n.tr("settings.about.updates.check_now", fallback: "Check for Updates…")) {
                        self.updater.checkForUpdates(nil)
                    }
                }
            } else {
                Text(self.updater.unavailableReason ??
                    L10n.tr("settings.about.updates.unavailable", fallback: "Updates unavailable in this build."))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr("settings.about.copyright", fallback: "© 2025 Peter Steinberger. MIT License."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .onAppear {
            guard !self.didLoadUpdaterState else { return }
            // Align Sparkle's flag with the persisted preference on first load.
            self.updater.automaticallyChecksForUpdates = self.autoUpdateEnabled
            self.updater.automaticallyDownloadsUpdates = self.autoUpdateEnabled
            self.didLoadUpdaterState = true
        }
        .onChange(of: self.autoUpdateEnabled) { _, newValue in
            self.updater.automaticallyChecksForUpdates = newValue
            self.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    private var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: self.updateChannelRaw) ?? .stable
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { self.updateChannel },
            set: { newValue in
                self.updateChannelRaw = newValue.rawValue
                self.updater.checkForUpdates(nil)
            })
    }

    private func openProjectHome() {
        guard let url = URL(string: "https://github.com/steipete/CodexBar") else { return }
        NSWorkspace.shared.open(url)
    }
}
