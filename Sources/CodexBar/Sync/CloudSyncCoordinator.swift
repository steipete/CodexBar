import CloudKit
import CodexBarCore
import Foundation
import Observation

@MainActor
final class CloudSyncCoordinator {
    let state: CloudSyncState

    private let settings: SettingsStore
    private let engine: CloudSyncEngine
    private var observers: [NSObjectProtocol] = []
    private var preferencesImportObserver: NSObjectProtocol?
    private var resumeTask: Task<Void, Never>?
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
        self.state.removeDeviceHandler = { [weak self] deviceID in
            await self?.engine.removeDevice(deviceID)
        }
    }

    func start() {
        self.observeSettings()
        self.preferencesImportObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(PreferencesDocument.importNotification), object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.consumePendingPreferencesImport() }
        }
        self.settings.consumePendingPreferencesImport()
        let configNotifications: [Notification.Name] = [
            .codexbarProviderConfigDidChange, .codexbarLocalConfigFileDidChange,
        ]
        self.observers = configNotifications.map { name in
            NotificationCenter.default
                .addObserver(forName: name, object: self.settings, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.configurationDidChangeLocally() }
                }
        }
        self.observers.append(NotificationCenter.default.addObserver(
            forName: .codexbarUsageSnapshotsDidChange,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let event = notification.object as? UsageSnapshotsDidChangeEvent else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.engine.queueSnapshots(event.snapshots)
            }
        })
        self.observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleResume(debounce: true)
            }
        })
        Task { await self.engine.start(enabled: self.settings.iCloudSyncEnabled) }
    }

    func applicationDidBecomeActive() {
        self.scheduleResume(debounce: false)
    }

    func didReceiveRemoteNotification(_ userInfo: [String: Any]) {
        Self.routeRemoteNotification(userInfo, enabled: self.settings.iCloudSyncEnabled) {
            self.scheduleResume(debounce: false)
        }
    }

    static func routeRemoteNotification(_ userInfo: [String: Any], enabled: Bool, fetch: () -> Void) {
        guard enabled,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKDatabaseNotification,
              notification.containerIdentifier == CloudSyncEngine.containerIdentifier,
              notification.databaseScope == .private else { return }
        fetch()
    }

    private func configurationDidChangeLocally() {
        let config = self.settings.configSnapshot
        Task {
            await self.engine.localUserConfigurationDidChange(config)
            await self.engine.scheduleConfigurationPush()
        }
    }

    func stop() {
        if let preferencesImportObserver {
            DistributedNotificationCenter.default().removeObserver(preferencesImportObserver)
            self.preferencesImportObserver = nil
        }
        self.observers.forEach(NotificationCenter.default.removeObserver)
        self.observers.removeAll()
        self.resumeTask?.cancel()
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
