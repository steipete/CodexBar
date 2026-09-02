import CloudKit
import CodexBarCore
import Foundation
import Observation

@MainActor
final class CloudSyncCoordinator {
    let state: CloudSyncState

    private let settings: SettingsStore
    private let engine: CloudSyncEngine
    private var configObserver: NSObjectProtocol?
    private var localFileConfigObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private var resumeTask: Task<Void, Never>?
    private var rehydrateTask: Task<Void, Never>?
    private var observedEnabled: Bool

    init(
        settings: SettingsStore,
        state: CloudSyncState = CloudSyncState(),
        persistence: CloudSyncPersistence = CloudSyncPersistence())
    {
        self.settings = settings
        self.state = state
        self.observedEnabled = settings.iCloudSyncEnabled
        self.engine = CloudSyncEngine(
            settings: settings,
            state: self.state,
            persistence: persistence,
            initialConfiguration: settings.configSnapshot,
            initialPreferences: settings.syncedPreferences,
            initialIncludeSecrets: settings.iCloudSyncIncludeSecrets)
    }

    func start() {
        self.observeSettings()
        // The Macs list has to render with syncing off, or there is nothing to remove a stale
        // device from. Local persistence only; the fleet menu cards stay gated on the setting.
        self.rehydrateTask = Task { await self.engine.rehydrateFleetStateIfNeeded() }
        self.state.removeDevice = { [weak self] deviceID in
            guard let self else { return }
            Task { await self.engine.removeDevice(deviceID: deviceID) }
        }
        self.configObserver = NotificationCenter.default.addObserver(
            forName: .codexbarProviderConfigDidChange,
            object: self.settings,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configurationDidChangeLocally()
            }
        }
        self.localFileConfigObserver = NotificationCenter.default.addObserver(
            forName: .codexbarLocalConfigFileDidChange,
            object: self.settings,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configurationDidChangeLocally()
            }
        }
        self.snapshotObserver = NotificationCenter.default.addObserver(
            forName: .codexbarUsageSnapshotsDidChange,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let event = notification.object as? UsageSnapshotsDidChangeEvent else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.engine.queueSnapshots(event.snapshots)
            }
        }
        self.accountObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleResume(debounce: true)
            }
        }
        Task { await self.engine.start(enabled: self.settings.iCloudSyncEnabled) }
    }

    func applicationDidBecomeActive() {
        self.scheduleResume(debounce: false)
    }

    private func configurationDidChangeLocally() {
        let config = self.settings.configSnapshot
        Task {
            await self.engine.localUserConfigurationDidChange(config)
            await self.engine.scheduleConfigurationPush()
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if let localFileConfigObserver {
            NotificationCenter.default.removeObserver(localFileConfigObserver)
        }
        if let snapshotObserver {
            NotificationCenter.default.removeObserver(snapshotObserver)
        }
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
        self.resumeTask?.cancel()
        self.rehydrateTask?.cancel()
        self.state.removeDevice = nil
        self.configObserver = nil
        self.localFileConfigObserver = nil
        self.snapshotObserver = nil
        self.accountObserver = nil
        self.resumeTask = nil
        Task { await self.engine.stop() }
    }

    private func scheduleResume(debounce: Bool) {
        self.resumeTask?.cancel()
        self.resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self.engine.resumeOrFetch(enabled: self.settings.iCloudSyncEnabled)
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = self.settings.iCloudSyncEnabled
            _ = self.settings.iCloudSyncIncludeSecrets
            _ = self.settings.iCloudSyncSnapshotsEnabled
            _ = self.settings.syncedPreferences
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettings()
                let enabled = self.settings.iCloudSyncEnabled
                if enabled != self.observedEnabled {
                    self.observedEnabled = enabled
                    await self.engine.setEnabled(enabled)
                } else {
                    await self.engine.localUserPreferencesDidChange(self.settings.syncedPreferences)
                    await self.engine.localIncludeSecretsDidChange(
                        self.settings.iCloudSyncIncludeSecrets,
                        config: self.settings.configSnapshot)
                    await self.engine.scheduleConfigurationPush()
                }
            }
        }
    }
}
