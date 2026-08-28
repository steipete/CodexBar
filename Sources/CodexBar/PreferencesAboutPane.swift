import AppKit
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
        Form {
            Section {
                self.hero
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            if self.updater.isAvailable {
                Section {
                    Toggle(L("check_updates_auto"), isOn: self.$autoUpdateEnabled)

                    Picker(selection: self.updateChannelBinding) {
                        ForEach(UpdateChannel.allCases) { channel in
                            Text(channel.displayName).tag(channel)
                        }
                    } label: {
                        SettingsRowLabel(L("update_channel"), subtitle: self.updateChannel.description)
                    }

                    LabeledContent(String(format: L("version_format"), self.versionString)) {
                        Button(L("check_for_updates")) { self.updater.checkForUpdates(nil) }
                    }
                } header: {
                    Text(L("section_updates"))
                }
            } else {
                Section {
                    Text(self.updater.unavailableReason ?? L("updates_unavailable"))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: L("link_github"),
                    url: "https://github.com/steipete/CodexBar")
                AboutLinkRow(icon: "globe", title: L("link_website"), url: "https://steipete.me")
                AboutLinkRow(icon: "bird", title: L("link_twitter"), url: "https://twitter.com/steipete")
                AboutLinkRow(icon: "envelope", title: L("link_email"), url: "mailto:peter@steipete.me")
            } header: {
                Text(L("section_links"))
            } footer: {
                Text(L("copyright"))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
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

    private var hero: some View {
        VStack(spacing: 10) {
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
                .focusEffectDisabled()
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        self.iconHover = hovering
                    }
                }
            }

            VStack(spacing: 2) {
                Text("CodexBar")
                    .font(.title3).bold()
                Text(String(format: L("version_format"), self.versionString))
                    .foregroundStyle(.secondary)
                if let buildTimestamp {
                    Text(String(format: L("built_format"), buildTimestamp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(L("about_tagline"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
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

@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(self.title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(self.hovering ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
    }
}
