import SwiftUI

struct SettingsView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.liveActivitiesEnabled, store: UserDefaults(suiteName: MobileAppGroup.identifier))
    private var liveActivitiesEnabled = false

    var body: some View {
        NavigationStack {
            @Bindable var coordinator = self.coordinator
            Form {
                Section {
                    Toggle(isOn: $coordinator.lanEnabled) {
                        Label("Local network (LAN)", systemImage: "wifi")
                    }
                    Toggle(isOn: $coordinator.iCloudEnabled) {
                        Label("iCloud sync", systemImage: "icloud")
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("LAN gives instant updates when your Mac and iPhone share Wi-Fi. iCloud keeps widgets and the Lock Screen fresh anywhere — using your own iCloud account, no server required.")
                }

                Section {
                    LabeledContent("Local network") {
                        Text(self.lanStatusText).foregroundStyle(.secondary)
                    }
                    LabeledContent("iCloud") {
                        Text(self.coordinator.iCloudAvailable ? "Available" : "Unavailable")
                            .foregroundStyle(.secondary)
                    }
                    if let metadata = self.coordinator.metadata {
                        LabeledContent("Last update") {
                            Text(UsageFormat.relative(metadata.snapshotGeneratedAt ?? metadata.receivedAt))
                                .foregroundStyle(.secondary)
                        }
                        if let device = metadata.senderDeviceName {
                            LabeledContent("From") { Text(device).foregroundStyle(.secondary) }
                        }
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    Toggle(isOn: self.$liveActivitiesEnabled) {
                        Label("Enable Live Activities", systemImage: "bolt.badge.clock")
                    }
                } header: {
                    Text("Live Activities")
                } footer: {
                    Text("Off by default. When on, you can pin a provider's usage to the Lock Screen and Dynamic Island from its detail screen. Updates while the app is open or refreshed in the background.")
                }

                Section {
                    LabeledContent("Data model", value: "Read-only mirror")
                    LabeledContent("Providers", value: "\(self.coordinator.snapshot?.entries.count ?? 0)")
                } header: {
                    Text("About")
                } footer: {
                    Text("CodexBar for iPhone mirrors the usage your Mac already aggregates. No provider credentials are stored on this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { self.dismiss() }
                }
            }
        }
    }

    private var lanStatusText: String {
        switch self.coordinator.lanStatus {
        case .connected: "Connected"
        case .searching: "Searching…"
        case .idle: "Off"
        }
    }
}
