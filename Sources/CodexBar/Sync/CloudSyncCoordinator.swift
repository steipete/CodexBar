import CodexBarCore
import Foundation
import Observation

@MainActor
final class CloudSyncCoordinator {
    let state: CloudSyncState

    private let settings: SettingsStore
    private let engine: CloudSyncEngine
    private var configObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var observedEnabled: Bool

    init(settings: SettingsStore, state: CloudSyncState = CloudSyncState()) {
        self.settings = settings
        self.state = state
        self.observedEnabled = settings.iCloudSyncEnabled
        self.engine = CloudSyncEngine(settings: settings, state: self.state)
    }

    func start() {
        self.observeSettings()
        self.configObserver = NotificationCenter.default.addObserver(
            forName: .codexbarProviderConfigDidChange,
            object: self.settings,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.engine.scheduleConfigurationPush() }
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
        Task { await self.engine.start(enabled: self.settings.iCloudSyncEnabled) }
    }

    func applicationDidBecomeActive() {
        Task { await self.engine.fetchChanges() }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if let snapshotObserver {
            NotificationCenter.default.removeObserver(snapshotObserver)
        }
        self.configObserver = nil
        self.snapshotObserver = nil
        Task { await self.engine.stop() }
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
                    await self.engine.scheduleConfigurationPush()
                }
            }
        }
    }
}
