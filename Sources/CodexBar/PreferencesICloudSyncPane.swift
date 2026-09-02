import CodexBarCore
import SwiftUI

@MainActor
struct ICloudSyncPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var state: CloudSyncState
    @State private var deviceToRemove: DeviceSyncPayload?
    private static let securityFootnote =
        "Secrets use iCloud end-to-end encryption via encryptedValues. " +
        "Hooks and machine-local paths never sync."

    var body: some View {
        Form {
            if self.state.status.needsAppUpdate {
                Section {
                    Label(
                        L("Sync is paused: another Mac uses a newer version of CodexBar. Update to resume."),
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Section {
                Toggle(
                    L("Sync settings and providers across your Macs via iCloud"),
                    isOn: self.primarySyncBinding)
                    .toggleStyle(.checkbox)
                    .disabled(!self.syncCanBeEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L("Include API keys, cookies, and tokens"), isOn: self.includeSecretsBinding)
                    Toggle(L("Sync usage snapshots"), isOn: self.snapshotsBinding)
                    Toggle(L("Show accounts from other Macs"), isOn: self.showFleetAccountsBinding)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 20)
                .disabled(!self.syncCanRun)
            } header: {
                Text(L("iCloud Sync"))
            } footer: {
                if let availabilityMessage = self.availabilityMessage {
                    SettingsSectionFooter(availabilityMessage)
                }
            }

            Section {
                LabeledContent(
                    L("Last successful fetch"),
                    value: self.relativeTime(self.state.status.lastSuccessfulFetchAt))
                LabeledContent(
                    L("Last successful push"),
                    value: self.relativeTime(self.state.status.lastSuccessfulPushAt))
            } header: {
                Text(L("Status"))
            } footer: {
                if let lastError = self.state.status.lastError {
                    SettingsSectionFooter {
                        Text(lastError).foregroundStyle(.red)
                    }
                }
            }

            Section {
                if self.devices.isEmpty {
                    Text(L("No synced Macs yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.devices, id: \.deviceID) { device in
                        ICloudSyncDeviceRow(
                            device: device,
                            isCurrentDevice: device.deviceID == self.settings.iCloudSyncDeviceID,
                            canRemove: self.settings.iCloudSyncEnabled && self.syncCanRun,
                            onRemove: { self.deviceToRemove = device })
                    }
                }
            } header: {
                Text(L("Macs"))
            } footer: {
                SettingsSectionFooter(self.macsFootnote)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            self.removalPrompt,
            isPresented: self.removalPromptBinding,
            titleVisibility: .visible)
        {
            Button(L("Remove"), role: .destructive) {
                if let device = self.deviceToRemove {
                    self.state.removeDevice?(device.deviceID)
                }
                self.deviceToRemove = nil
            }
            Button(L("Cancel"), role: .cancel) { self.deviceToRemove = nil }
        } message: {
            // Two Macs can share a host name, which is the case this issue is about, so the
            // dialog has to say which row it means. Relative dates collide; absolute ones do not.
            if let device = self.deviceToRemove {
                Text(String(
                    format: L("Last seen %@"),
                    device.lastSeen.formatted(date: .abbreviated, time: .shortened)))
            }
        }
    }

    /// A device row stays visible with syncing off, so the footer has to say why its remove
    /// button is dead: the delete has to reach CloudKit, which needs the engine running. The
    /// other two reasons a row cannot be removed — a paused sync and an unavailable iCloud
    /// account — already show their own message further up, so this covers only the setting.
    private var macsFootnote: String {
        guard !self.settings.iCloudSyncEnabled, !self.devices.isEmpty else {
            return L(Self.securityFootnote)
        }
        return L(Self.securityFootnote) + " " + L("Turn on iCloud Sync to remove a Mac.")
    }

    private var removalPrompt: String {
        guard let device = self.deviceToRemove else { return "" }
        return L("Remove %@ and its usage snapshots from iCloud?", device.hostName)
    }

    private var removalPromptBinding: Binding<Bool> {
        Binding(
            get: { self.deviceToRemove != nil },
            set: { presented in
                if !presented {
                    self.deviceToRemove = nil
                }
            })
    }

    private var syncCanBeEnabled: Bool {
        self.state.availability == .available
    }

    private var syncCanRun: Bool {
        self.syncCanBeEnabled && !self.state.status.needsAppUpdate
    }

    private var availabilityMessage: String? {
        switch self.state.availability {
        case .available:
            nil
        case .missingEntitlement:
            L("Requires a signed release build of CodexBar.")
        case .noICloudAccount:
            L("Sign in to iCloud in System Settings to enable sync.")
        case .restricted:
            L("iCloud access is restricted on this Mac.")
        }
    }

    private var devices: [DeviceSyncPayload] {
        self.state.fleetDevices.values.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.deviceID == self.settings.iCloudSyncDeviceID
            let rhsIsCurrent = rhs.deviceID == self.settings.iCloudSyncDeviceID
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
        }
    }

    private var primarySyncBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncEnabled },
            set: { self.settings.iCloudSyncEnabled = $0 })
    }

    private var includeSecretsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncIncludeSecrets },
            set: { self.settings.iCloudSyncIncludeSecrets = $0 })
    }

    private var snapshotsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncSnapshotsEnabled },
            set: { self.settings.iCloudSyncSnapshotsEnabled = $0 })
    }

    private var showFleetAccountsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.iCloudSyncShowFleetAccounts },
            set: { self.settings.iCloudSyncShowFleetAccounts = $0 })
    }

    private func relativeTime(_ date: Date?) -> String {
        date?.relativeDescription() ?? L("Never")
    }
}

private struct ICloudSyncDeviceRow: View {
    let device: DeviceSyncPayload
    let isCurrentDevice: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.device.hostName)
                Text(String(format: L("Last seen %@"), self.device.lastSeen.relativeDescription()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if self.isCurrentDevice {
                Text(L("This Mac"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Button(action: self.onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!self.canRemove)
            .help(L("Remove"))
        }
    }
}
