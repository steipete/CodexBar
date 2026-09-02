import CloudKit
import CodexBarCore
import Foundation
import Observation
import Security

enum SyncAvailability: Equatable, Sendable {
    case available
    case missingEntitlement
    case noICloudAccount
    case restricted
}

struct SyncStatus: Equatable, Sendable {
    var needsAppUpdate = false
    var lastError: String?
    var lastSuccessfulFetchAt: Date?
    var lastSuccessfulPushAt: Date?
}

@MainActor
@Observable
final class CloudSyncState {
    var availability: SyncAvailability = .available
    var status = SyncStatus()
    var fleetDevices: [String: DeviceSyncPayload] = [:]
    var fleetSnapshots: [String: AccountSnapshotSyncPayload] = [:]
    /// Wired by `CloudSyncCoordinator`; the settings pane's only route into the sync engine.
    @ObservationIgnored var removeDevice: ((String) -> Void)?
}

struct CloudSyncQuotaRetryState: Equatable, Sendable {
    private(set) var baseDelay: TimeInterval?
    private(set) var failureCount = 0

    mutating func nextDelay(serverRetryAfter: TimeInterval?) -> TimeInterval {
        if self.baseDelay == nil {
            self.baseDelay = max(serverRetryAfter ?? 60, 0)
        }
        let multiplier = pow(2, Double(self.failureCount))
        self.failureCount += 1
        return min((self.baseDelay ?? 60) * multiplier, 60 * 60)
    }

    mutating func reset() {
        self = Self()
    }
}

/// Runs CKSyncEngine delegate events serially without retaining the delegate callback's task context.
final class CloudSyncDelegateEventQueue: Sendable {
    typealias Operation = @Sendable () async -> Void

    private let continuation: AsyncStream<Operation>.Continuation
    private let worker: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        self.continuation = continuation
        self.worker = Task.detached(priority: .utility) {
            for await operation in stream {
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    deinit {
        self.continuation.finish()
        self.worker.cancel()
    }

    func enqueue(_ operation: @escaping Operation) {
        self.continuation.yield(operation)
    }
}

enum CloudSyncBatchRecordProvider {
    static func record(
        for recordID: CKRecord.ID,
        desiredRecords: [CKRecord.ID: CKRecord],
        removePendingChange: (CKSyncEngine.PendingRecordZoneChange) -> Void) -> CKRecord?
    {
        guard let record = desiredRecords[recordID] else {
            removePendingChange(.saveRecord(recordID))
            return nil
        }
        return record
    }
}

enum CloudSyncDirtyState {
    private static let providerIntentPrefix = "intent-"

    static func configurationRecordNamesToQueue(
        envelope: CloudSyncPersistence.Envelope,
        configuredProviders: [ProviderInstanceID]) -> Set<String>
    {
        var recordNames = Set(configuredProviders.compactMap { provider in
            envelope.dirtyProviders.contains(provider.rawValue)
                ? ProviderIntentPayload.recordName(for: provider)
                : nil
        })
        if envelope.preferencesDirty {
            recordNames.insert(PreferencesSyncPayload.recordName)
        }
        return recordNames
    }

    static func markBootstrapDirtyIfNeeded(
        configuredProviders: [ProviderInstanceID],
        envelope: inout CloudSyncPersistence.Envelope)
    {
        guard !envelope.recordMetadata.keys.contains(where: { $0.hasPrefix(self.providerIntentPrefix) }) else {
            return
        }
        envelope.dirtyProviders.formUnion(configuredProviders.map(\.rawValue))
        envelope.preferencesDirty = true
    }

    static func clearSavedRecords(
        _ recordNames: some Sequence<String>,
        envelope: inout CloudSyncPersistence.Envelope)
    {
        for recordName in recordNames {
            if recordName == PreferencesSyncPayload.recordName {
                envelope.preferencesDirty = false
            } else if recordName.hasPrefix(self.providerIntentPrefix) {
                envelope.dirtyProviders.remove(String(recordName.dropFirst(self.providerIntentPrefix.count)))
            }
        }
    }

    static func providerSyncContentChanged(
        from previous: ProviderConfig,
        previousSuppressedEnableIntents: Set<String>,
        to current: ProviderConfig,
        currentSuppressedEnableIntents: Set<String>) throws -> Bool
    {
        let previousPayload = CloudSyncEngine.providerIntentPayload(
            config: previous,
            suppressedEnableIntents: previousSuppressedEnableIntents)
        let currentPayload = CloudSyncEngine.providerIntentPayload(
            config: current,
            suppressedEnableIntents: currentSuppressedEnableIntents)
        guard try CanonicalSyncJSON.encode(previousPayload) == CanonicalSyncJSON.encode(currentPayload) else {
            return true
        }
        let previousSecrets = try ProviderIntentPayload.secretFields(for: previous, includeSecrets: true)
        let currentSecrets = try ProviderIntentPayload.secretFields(for: current, includeSecrets: true)
        return previousSecrets != currentSecrets
    }
}

enum CloudSyncDeviceRemoval {
    /// Everything a device owns in the sync zone: its device record plus every usage snapshot it
    /// published. Snapshots outlive the device record otherwise, and the menu keeps projecting them.
    static func recordNames(
        forDeviceID deviceID: String,
        snapshots: [String: AccountSnapshotSyncPayload]) -> Set<String>
    {
        var names: Set<String> = [DeviceSyncPayload.recordName(for: deviceID)]
        for (name, snapshot) in snapshots where snapshot.deviceID == deviceID {
            names.insert(name)
        }
        return names
    }

    /// Usage Snapshots left behind by a Device Record that is already gone. CloudKit can confirm
    /// the device delete and terminally reject one of its snapshot deletes in the same batch, and
    /// the leftover snapshot would otherwise keep projecting into the fleet menu with no Macs row
    /// left to remove it from.
    static func orphanedSnapshotNames(
        removedNames: Set<String>,
        snapshots: [String: AccountSnapshotSyncPayload]) -> Set<String>
    {
        Set(snapshots.compactMap { name, snapshot in
            removedNames.contains(DeviceSyncPayload.recordName(for: snapshot.deviceID)) ? name : nil
        })
    }
}

enum CloudSyncSnapshotMigration {
    static func obsoleteRecordNames(
        liveSnapshots: [AccountSnapshotSyncPayload],
        hashes: [String: String],
        envelope: CloudSyncPersistence.Envelope) -> Set<String>
    {
        AccountSnapshotSyncPayload.obsoleteEmailKeyedRecordNames(
            liveSnapshots: liveSnapshots,
            knownRecordNames: Set(hashes.keys).union(envelope.fleetSnapshots.keys))
    }

    /// Stops pushing these records and hands back the IDs to delete. The fleet rows are left
    /// alone: they go when CloudKit confirms the delete, not when it is queued.
    static func dropPushState(
        _ names: Set<String>,
        hashes: inout [String: String],
        envelope: inout CloudSyncPersistence.Envelope,
        desiredRecords: inout [CKRecord.ID: CKRecord],
        zoneID: CKRecordZone.ID) -> [CKRecord.ID]
    {
        names.map { name in
            let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
            desiredRecords.removeValue(forKey: recordID)
            hashes.removeValue(forKey: name)
            envelope.encodedSystemFields.removeValue(forKey: name)
            envelope.recordMetadata.removeValue(forKey: name)
            return recordID
        }
    }

    static func predecessorNames(
        for snapshot: AccountSnapshotSyncPayload,
        obsoleteNames: Set<String>) -> Set<String>
    {
        guard let predecessor = snapshot.emailKeyedPredecessorRecordName(),
              obsoleteNames.contains(predecessor)
        else {
            return []
        }
        return [predecessor]
    }

    static func takeDeletes(
        forSavedRecordNames savedNames: [String],
        pending: inout [String: Set<String>],
        afterLiveSnapshotReconciliation hasReconciledLiveSnapshots: Bool) -> Set<String>
    {
        guard hasReconciledLiveSnapshots else { return [] }
        return self.takeDeletes(forSavedRecordNames: savedNames, pending: &pending)
    }

    static func takeDeletes(
        forSavedRecordNames savedNames: [String],
        pending: inout [String: Set<String>]) -> Set<String>
    {
        var toDrop: Set<String> = []
        for name in savedNames {
            if let obsolete = pending.removeValue(forKey: name) {
                toDrop.formUnion(obsolete)
            }
        }
        let stillReferenced = Set(pending.values.joined())
        return toDrop.subtracting(stillReferenced)
    }

    static func retainingObsoletePredecessors(
        in pending: inout [String: Set<String>],
        obsoleteNames: Set<String>)
    {
        pending = pending.compactMapValues { predecessors in
            let live = predecessors.intersection(obsoleteNames)
            return live.isEmpty ? nil : live
        }
    }

    static func assigningPredecessors(
        _ predecessors: Set<String>,
        to replacement: String,
        pending: inout [String: Set<String>])
    {
        if predecessors.isEmpty {
            pending.removeValue(forKey: replacement)
        } else {
            pending[replacement] = predecessors
        }
    }

    static func cancelledPersistedDeletes(
        pendingDeletes: Set<String>,
        liveNames: Set<String>) -> Set<String>
    {
        pendingDeletes.intersection(liveNames)
    }

    static func pendingDeletesToRequeue(
        pendingDeletes: Set<String>,
        liveNames: Set<String>) -> Set<String>
    {
        pendingDeletes.subtracting(liveNames)
    }

    static func liveSnapshotRecordNames(
        pendingRecordNames: some Sequence<String>,
        storedRecordNames: some Sequence<String>) -> Set<String>
    {
        Set(pendingRecordNames).union(storedRecordNames)
    }

    /// Whether a failed delete gets another go. A Device Record never does: a retry would race
    /// the Mac that owns it re-registering itself, and delete the fresh record it just published.
    /// CloudKit has already dropped the change from its pending set by the time this is asked,
    /// so "no retry" means the engine simply does not queue it again.
    static func isRetryableDelete(_ recordID: CKRecord.ID, error: CKError) -> Bool {
        self.retryDelay(for: error) != nil && !DeviceSyncPayload.isRecordName(recordID.recordName)
    }

    static func retryableFailedDeletes(
        _ failures: [CKRecord.ID: CKError],
        liveNames: Set<String> = []) -> [CKRecord.ID]
    {
        failures.compactMap { recordID, error in
            guard self.isRetryableDelete(recordID, error: error) else { return nil }
            guard !liveNames.contains(recordID.recordName) else { return nil }
            return recordID
        }
    }

    /// Failures the user has to hear about, because nothing else will fix them: anything that
    /// gets no retry. `unknownItem` never counts, since that record is already gone.
    static func reportableFailedDeletes(_ failures: [CKRecord.ID: CKError]) -> [CKError] {
        failures.compactMap { recordID, error in
            guard error.code != .unknownItem else { return nil }
            return self.isRetryableDelete(recordID, error: error) ? nil : error
        }
    }

    /// Delayed retries only for recoverable CloudKit failures. Terminal per-record errors such as
    /// `permissionFailure`, `notAuthenticated`, and `invalidArguments` are reported once.
    static func retryDelay(for error: CKError) -> TimeInterval? {
        switch error.code {
        case .unknownItem, .permissionFailure, .notAuthenticated, .invalidArguments:
            return nil
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .quotaExceeded,
             .serverResponseLost, .accountTemporarilyUnavailable:
            return max(error.retryAfterSeconds ?? 1, 1)
        default:
            guard let retryAfter = error.retryAfterSeconds else { return nil }
            return max(retryAfter, 1)
        }
    }

    /// Names the engine stops tracking after a failed delete: everything that gets no retry.
    static func finishedFailedDeleteNames(_ failures: [CKRecord.ID: CKError]) -> Set<String> {
        Set(failures.compactMap { recordID, error in
            self.isRetryableDelete(recordID, error: error) ? nil : recordID.recordName
        })
    }

    /// Names CloudKit no longer holds: confirmed deletes, plus records that were already gone.
    /// Fleet rows go on this signal alone, so a failed delete leaves the Mac in the list rather
    /// than hiding a Device Record that is still there.
    static func confirmedDeletedNames(
        deletedIDs: [CKRecord.ID],
        failures: [CKRecord.ID: CKError]) -> Set<String>
    {
        Set(deletedIDs.map(\.recordName)).union(
            failures.compactMap { $0.value.code == .unknownItem ? $0.key.recordName : nil })
    }

    static func abandonedReplacementNames(
        failures: [String: CKError],
        pendingReplacements: Set<String>) -> Set<String>
    {
        Set(failures.compactMap { name, error in
            pendingReplacements.contains(name) && self.retryDelay(for: error) == nil ? name : nil
        })
    }

    static func applyConfirmedSaveHashes(
        savedRecordNames: [String],
        pendingSaveHashes: inout [String: String],
        lastSnapshotHashes: inout [String: String])
    {
        for name in savedRecordNames {
            guard let hash = pendingSaveHashes.removeValue(forKey: name) else { continue }
            lastSnapshotHashes[name] = hash
        }
    }

    static func applyTerminalSaveSkip(
        recordName: String,
        error: CKError,
        pendingSaveHashes: inout [String: String],
        skippedTerminalReplacementHashes: inout [String: String])
    {
        guard self.retryDelay(for: error) == nil else { return }
        guard let hash = pendingSaveHashes.removeValue(forKey: recordName) else { return }
        skippedTerminalReplacementHashes[recordName] = hash
    }

    static func hasInFlightSave(recordName: String, pendingSaveHashes: [String: String]) -> Bool {
        pendingSaveHashes[recordName] != nil
    }

    static func mergingPendingSnapshots(
        _ pending: [AccountSnapshotSyncPayload],
        with extras: [AccountSnapshotSyncPayload]) -> [AccountSnapshotSyncPayload]
    {
        var byName: [String: Int] = [:]
        var result = pending
        for (index, payload) in pending.enumerated() {
            byName[payload.recordName] = index
        }
        for payload in extras where byName[payload.recordName] == nil {
            byName[payload.recordName] = result.count
            result.append(payload)
        }
        return result
    }

    static func unpublishedFleetSnapshots(
        savedRecordNames: [String],
        fleetSnapshots: [String: AccountSnapshotSyncPayload],
        lastSnapshotHashes: [String: String]) -> [AccountSnapshotSyncPayload]
    {
        savedRecordNames.compactMap { name in
            guard let payload = fleetSnapshots[name],
                  let hash = try? CanonicalSyncJSON.hash(payload),
                  lastSnapshotHashes[name] != hash
            else { return nil }
            return payload
        }
    }

    static func shouldResumeDelayedRetry(
        originatingEngine: ObjectIdentifier?,
        currentEngine: ObjectIdentifier?) -> Bool
    {
        guard let originatingEngine, let currentEngine else { return false }
        return originatingEngine == currentEngine
    }
}

enum CloudSyncEntitlementGate {
    static let entitlement = "com.apple.developer.icloud-services"

    static func hasICloudServicesEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, self.entitlement as CFString, nil)
        else {
            return false
        }
        if let services = value as? [String] {
            return services.contains("CloudKit")
        }
        return false
    }
}

actor CloudSyncEngine: CKSyncEngineDelegate {
    static let containerIdentifier = "iCloud.com.steipete.codexbar"
    static let zoneID = CKRecordZone.ID(zoneName: "CodexBarSync", ownerName: CKCurrentUserDefaultName)

    private let settings: SettingsStore
    private let state: CloudSyncState
    private let persistence: CloudSyncPersistence
    private nonisolated let delegateEventQueue = CloudSyncDelegateEventQueue()
    private var persistenceEnvelope: CloudSyncPersistence.Envelope
    private var engine: CKSyncEngine?
    private var desiredRecords: [CKRecord.ID: CKRecord] = [:]
    private var enabled = false
    private var configPushTask: Task<Void, Never>?
    private var snapshotPushTask: Task<Void, Never>?
    private var periodicFetchTask: Task<Void, Never>?
    private var lastSnapshotPushAt: Date?
    private var pendingSnapshots: [AccountSnapshotSyncPayload] = []
    private var lastSnapshotHashes: [String: String] = [:]
    private var skippedTerminalReplacementHashes: [String: String] = [:]
    private var pendingSaveHashes: [String: String] = [:]
    private var lastKnownProviderConfigs: [ProviderInstanceID: ProviderConfig] = [:]
    private var lastKnownPreferences: SyncedPreferences?
    private var lastKnownIncludeSecrets: Bool?
    private var quotaRetryState = CloudSyncQuotaRetryState()
    private var didRehydrateFleetState = false
    /// Restored predecessor mappings must not delete until local live snapshots have been applied.
    private var hasReconciledLiveSnapshots = false
    private let logger = CodexBarLog.logger(LogCategories.settings)

    init(
        settings: SettingsStore,
        state: CloudSyncState,
        persistence: CloudSyncPersistence = CloudSyncPersistence(),
        initialConfiguration: CodexBarConfig? = nil,
        initialPreferences: SyncedPreferences? = nil,
        initialIncludeSecrets: Bool? = nil)
    {
        self.settings = settings
        self.state = state
        self.persistence = persistence
        self.persistenceEnvelope = persistence.load()
        if let initialConfiguration {
            self.lastKnownProviderConfigs = Dictionary(
                uniqueKeysWithValues: initialConfiguration.providers.map { ($0.id, $0) })
        }
        self.lastKnownPreferences = initialPreferences
        self.lastKnownIncludeSecrets = initialIncludeSecrets
    }

    func start(enabled: Bool) async {
        guard CloudSyncEntitlementGate.hasICloudServicesEntitlement() else {
            await self.updateAvailability(.missingEntitlement)
            return
        }
        await self.updateAvailability(.available)
        guard enabled else { return }
        await self.setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        guard enabled else {
            await self.stopEngine(clearPersistence: false)
            return
        }
        guard CloudSyncEntitlementGate.hasICloudServicesEntitlement() else {
            await self.updateAvailability(.missingEntitlement)
            return
        }
        do {
            let initialized = try await self.initializeEngineIfNeeded()
            guard self.engine != nil else { return }
            // First sync on this device: apply the fleet's existing state before composing
            // any push. Otherwise a fresh device's records (editCount 1, newer timestamps)
            // win conflict ties against the fleet's records and clobber them server-side.
            if !self.persistenceEnvelope.recordMetadata.keys.contains(where: { $0.hasPrefix("intent-") }) {
                await self.fetchChanges()
            }
            let configuredProviders = await MainActor.run { self.settings.configSnapshot.providers.map(\.id) }
            CloudSyncDirtyState.markBootstrapDirtyIfNeeded(
                configuredProviders: configuredProviders,
                envelope: &self.persistenceEnvelope)
            self.persistEnvelope()
            try await self.queueCurrentConfigurationAndPreferences()
            guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }
            try await self.queueDeviceRecord()
            self.startPeriodicFetchTimer()
            self.scheduleFetchChanges(scopedToSyncZone: !initialized)
        } catch {
            await self.record(error: error)
        }
    }

    func resumeOrFetch(enabled: Bool) async {
        guard enabled else { return }
        if self.engine == nil {
            await self.start(enabled: true)
        } else {
            await self.fetchChanges()
        }
    }

    func localUserConfigurationDidChange(_ config: CodexBarConfig) {
        let previousSuppressedEnableIntents = self.persistenceEnvelope.suppressedEnableIntents
        for providerConfig in config.providers {
            if let previous = self.lastKnownProviderConfigs[providerConfig.id],
               previous.enabled != providerConfig.enabled
            {
                self.persistenceEnvelope.suppressedEnableIntents.remove(providerConfig.id.rawValue)
            }
            guard let previous = self.lastKnownProviderConfigs[providerConfig.id] else {
                self.persistenceEnvelope.dirtyProviders.insert(providerConfig.id.rawValue)
                continue
            }
            do {
                if try CloudSyncDirtyState.providerSyncContentChanged(
                    from: previous,
                    previousSuppressedEnableIntents: previousSuppressedEnableIntents,
                    to: providerConfig,
                    currentSuppressedEnableIntents: self.persistenceEnvelope.suppressedEnableIntents)
                {
                    self.persistenceEnvelope.dirtyProviders.insert(providerConfig.id.rawValue)
                }
            } catch {
                self.persistenceEnvelope.dirtyProviders.insert(providerConfig.id.rawValue)
                self.logger.error("Failed to compare provider sync content: \(error)")
            }
        }
        self.lastKnownProviderConfigs = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
        self.persistEnvelope()
    }

    func localUserPreferencesDidChange(_ preferences: SyncedPreferences) {
        defer { self.lastKnownPreferences = preferences }
        guard let previous = self.lastKnownPreferences else { return }
        do {
            guard try CanonicalSyncJSON.encode(previous) != CanonicalSyncJSON.encode(preferences) else { return }
            self.persistenceEnvelope.preferencesDirty = true
            self.persistEnvelope()
        } catch {
            self.persistenceEnvelope.preferencesDirty = true
            self.persistEnvelope()
            self.logger.error("Failed to compare synced preferences: \(error)")
        }
    }

    func localIncludeSecretsDidChange(_ includeSecrets: Bool, config: CodexBarConfig) {
        defer { self.lastKnownIncludeSecrets = includeSecrets }
        guard let previous = self.lastKnownIncludeSecrets, previous != includeSecrets else { return }
        self.persistenceEnvelope.dirtyProviders.formUnion(config.providers.map(\.id.rawValue))
        self.persistEnvelope()
    }

    func scheduleConfigurationPush() {
        guard self.enabled, self.engine != nil else { return }
        self.configPushTask?.cancel()
        self.configPushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                try await self?.queueCurrentConfigurationAndPreferences()
            } catch is CancellationError {
                return
            } catch {
                await self?.record(error: error)
            }
        }
    }

    func queueSnapshots(_ snapshots: [AccountSnapshotSyncPayload]) async {
        guard self.enabled, self.engine != nil else { return }
        let options = await MainActor.run {
            (
                enabled: self.settings.iCloudSyncSnapshotsEnabled,
                lowPower: self.settings.backgroundWorkLowPowerModeEnabled
                    || ProcessInfo.processInfo.isLowPowerModeEnabled,
                needsAppUpdate: self.state.status.needsAppUpdate)
        }
        guard options.enabled, !options.lowPower, !options.needsAppUpdate else { return }
        self.pendingSnapshots = snapshots
        let elapsed = self.lastSnapshotPushAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed >= 120 {
            await self.pushPendingSnapshots()
            return
        }
        self.snapshotPushTask?.cancel()
        self.snapshotPushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(120 - elapsed))
                guard !Task.isCancelled else { return }
                await self?.pushPendingSnapshots()
            } catch {
                return
            }
        }
    }

    /// Reports whether the fleet cache is current. A caller about to act on that cache
    /// destructively has no grounds to when this comes back false.
    @discardableResult
    func fetchChanges() async -> Bool {
        guard self.enabled, let engine = self.engine else { return false }
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
            await MainActor.run { self.state.status.lastSuccessfulFetchAt = Date() }
            return true
        } catch {
            await self.record(error: error)
            return false
        }
    }

    func stop() async {
        self.enabled = false
        await self.stopEngine(clearPersistence: false)
    }

    private func initializeEngineIfNeeded() async throws -> Bool {
        guard self.engine == nil else { return false }
        // This is the first CKContainer access, and every path here has already passed the entitlement gate.
        let container = CKContainer(identifier: Self.containerIdentifier)
        let accountStatus = try await container.accountStatus()
        switch accountStatus {
        case .available:
            await self.updateAvailability(.available)
        case .restricted:
            await self.updateAvailability(.restricted)
            return false
        case .noAccount, .couldNotDetermine, .temporarilyUnavailable:
            await self.updateAvailability(.noICloudAccount)
            return false
        @unknown default:
            await self.updateAvailability(.noICloudAccount)
            return false
        }

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: self.persistenceEnvelope.stateSerialization,
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        await self.rehydrateFleetStateIfNeeded()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        return true
    }

    private func queueCurrentConfigurationAndPreferences() async throws {
        guard let engine = self.engine else { return }
        if self.persistenceEnvelope.recordMetadata.values.contains(where: {
            ($0.schemaVersion ?? 0) > CodexBarSyncSchema.currentVersion
        }) {
            await MainActor.run { self.state.status.needsAppUpdate = true }
            return
        }
        let snapshot = await MainActor.run {
            (
                config: self.settings.configSnapshot,
                includeSecrets: self.settings.iCloudSyncIncludeSecrets,
                preferences: self.settings.syncedPreferences)
        }
        for config in snapshot.config.providers where self.lastKnownProviderConfigs[config.id] == nil {
            self.lastKnownProviderConfigs[config.id] = config
        }
        if self.lastKnownPreferences == nil {
            self.lastKnownPreferences = snapshot.preferences
        }
        if self.lastKnownIncludeSecrets == nil {
            self.lastKnownIncludeSecrets = snapshot.includeSecrets
        }
        let recordNames = CloudSyncDirtyState.configurationRecordNamesToQueue(
            envelope: self.persistenceEnvelope,
            configuredProviders: snapshot.config.providers.map(\.id))
        for config in snapshot.config.providers
            where recordNames.contains(ProviderIntentPayload.recordName(for: config.id))
        {
            try self.queueProviderIntent(config, includeSecrets: snapshot.includeSecrets, engine: engine)
        }
        if recordNames.contains(PreferencesSyncPayload.recordName) {
            try self.queuePreferences(snapshot.preferences, engine: engine)
        }
    }

    private func queueProviderIntent(
        _ config: ProviderConfig,
        includeSecrets: Bool,
        engine: CKSyncEngine) throws
    {
        let intent = Self.providerIntentPayload(
            config: config,
            suppressedEnableIntents: self.persistenceEnvelope.suppressedEnableIntents)
        let payload = try CanonicalSyncJSON.string(intent)
        let recordID = self.recordID(named: ProviderIntentPayload.recordName(for: config.id))
        let record = self.record(type: .providerIntent, id: recordID)
        let existingSecretKeys = Set(record.encryptedValues.allKeys())
        let secretFields = try ProviderIntentPayload.secretFields(
            for: config,
            includeSecrets: includeSecrets,
            previouslyUploadedFields: existingSecretKeys)
        let unchanged = (record["payload"] as? String) == payload
            && self.encryptedStringFields(record) == secretFields
        guard !unchanged else { return }

        record["schemaVersion"] = CodexBarSyncSchema.currentVersion as CKRecordValue
        record["provider"] = config.id.rawValue as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["editCount"] = (self.editCount(record) + 1) as CKRecordValue
        record["modifiedAt"] = Date() as CKRecordValue
        for field in ProviderIntentSecretField.allCases {
            record.encryptedValues[field.rawValue] = nil
        }
        for (key, value) in secretFields {
            record.encryptedValues[key] = value as CKRecordValue
        }
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    static func providerIntentPayload(
        config: ProviderConfig,
        suppressedEnableIntents: Set<String>) -> ProviderIntentPayload
    {
        var payload = ProviderIntentPayload(config: config)
        if suppressedEnableIntents.contains(config.id.rawValue), config.enabled != true {
            payload.enabled = true
        }
        return payload
    }

    private func queuePreferences(_ preferences: SyncedPreferences, engine: CKSyncEngine) throws {
        let payload = try CanonicalSyncJSON.string(PreferencesSyncPayload(preferences: preferences))
        let recordID = self.recordID(named: PreferencesSyncPayload.recordName)
        let record = self.record(type: .preferences, id: recordID)
        guard (record["payload"] as? String) != payload else { return }
        record["schemaVersion"] = CodexBarSyncSchema.currentVersion as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["editCount"] = (self.editCount(record) + 1) as CKRecordValue
        record["modifiedAt"] = Date() as CKRecordValue
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func queueDeviceRecord() async throws {
        guard let engine = self.engine else { return }
        let deviceID = await MainActor.run { self.settings.iCloudSyncDeviceID }
        let payload = DeviceSyncPayload(
            deviceID: deviceID,
            hostName: ProcessInfo.processInfo.hostName,
            model: Self.deviceModel(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            lastSeen: Date())
        let recordID = self.recordID(named: payload.recordName)
        // This Mac may have been removed before quitting. Re-registering supersedes that removal,
        // so drop the pending delete rather than letting it retire the record we are about to save.
        self.cancelPendingRecordDeletes([payload.recordName])
        let record = self.record(type: .device, id: recordID)
        record["schemaVersion"] = payload.schemaVersion as CKRecordValue
        record["deviceID"] = payload.deviceID as CKRecordValue
        record["hostName"] = payload.hostName as CKRecordValue
        record["model"] = payload.model as CKRecordValue
        record["appVersion"] = payload.appVersion as CKRecordValue
        record["lastSeen"] = payload.lastSeen as CKRecordValue
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        self.persistenceEnvelope.fleetDevices[payload.recordName] = payload
        await MainActor.run { self.state.fleetDevices[payload.recordName] = payload }
        self.persistEnvelope()
    }

    // MARK: CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        self.delegateEventQueue.enqueue { [weak self] in
            await self?.processEvent(event, syncEngine: syncEngine)
        }
    }

    private func processEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            self.persistenceEnvelope.stateSerialization = update.stateSerialization
            self.persistEnvelope()
        case let .accountChange(change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                await self.stopEngine(clearPersistence: true)
            case .signIn:
                break
            @unknown default:
                await self.stopEngine(clearPersistence: true)
            }
        case let .fetchedRecordZoneChanges(changes):
            await self.applyFetchedRecords(changes.modifications.map(\.record))
            await self.forgetFleetRecords(Set(changes.deletions.map(\.recordID.recordName)))
            self.persistEnvelope()
            await MainActor.run { self.state.status.lastSuccessfulFetchAt = Date() }
        case let .sentRecordZoneChanges(changes):
            if !changes.savedRecords.isEmpty || !changes.deletedRecordIDs.isEmpty {
                self.quotaRetryState.reset()
            }
            for record in changes.savedRecords {
                self.cacheSystemFields(record)
                self.desiredRecords.removeValue(forKey: record.recordID)
            }
            CloudSyncDirtyState.clearSavedRecords(
                changes.savedRecords.map(\.recordID.recordName),
                envelope: &self.persistenceEnvelope)
            // Evaluate confirmed saves before abandoning terminal failures so a mixed batch
            // still counts a failed sibling's shared predecessor as referenced.
            await self.finishConfirmedSnapshotMigrations(
                savedRecordNames: changes.savedRecords.map(\.recordID.recordName),
                syncEngine: syncEngine)
            for failure in changes.failedRecordSaves {
                await self.handleSaveFailure(failure, syncEngine: syncEngine)
            }
            await self.handleSentRecordDeletes(
                deletedIDs: changes.deletedRecordIDs,
                failures: changes.failedRecordDeletes)
            self.persistEnvelope()
            if !changes.savedRecords.isEmpty {
                await MainActor.run { self.state.status.lastSuccessfulPushAt = Date() }
            }
            // Only a push with nothing the user has to hear about retires the banner. A batch that
            // saved one record and reported a failed delete has not fixed it, and a fetch never
            // does. Records CloudKit no longer holds are removals that landed, so they clear the
            // banner rather than block it.
            let landedDeletes = CloudSyncSnapshotMigration.confirmedDeletedNames(
                deletedIDs: changes.deletedRecordIDs,
                failures: changes.failedRecordDeletes)
            if changes.failedRecordSaves.isEmpty,
               CloudSyncSnapshotMigration.reportableFailedDeletes(changes.failedRecordDeletes).isEmpty,
               !changes.savedRecords.isEmpty || !landedDeletes.isEmpty
            {
                await MainActor.run { self.state.status.lastError = nil }
            }
            if !self.pendingSnapshots.isEmpty {
                Task { [weak self] in
                    await self?.pushPendingSnapshots()
                }
            }
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch?
    {
        await self.makeChangeBatch(context, syncEngine: syncEngine)
    }

    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch?
    {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            guard let self else { return nil }
            return await self.recordForPendingSave(recordID, syncEngine: syncEngine)
        }
    }

    private func recordForPendingSave(_ recordID: CKRecord.ID, syncEngine: CKSyncEngine) -> CKRecord? {
        CloudSyncBatchRecordProvider.record(for: recordID, desiredRecords: self.desiredRecords) { change in
            syncEngine.state.remove(pendingRecordZoneChanges: [change])
        }
    }

    func applyFetchedRecords(_ records: [CKRecord]) async {
        if records.contains(where: { self.schemaVersion($0) > CodexBarSyncSchema.currentVersion }) {
            await MainActor.run { self.state.status.needsAppUpdate = true }
            for record in records {
                self.cacheSystemFields(record)
            }
            return
        }
        guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }

        for record in records {
            self.cacheSystemFields(record)
            guard self.shouldApplyServerRecord(record) else { continue }
            do {
                switch record.recordType {
                case SyncRecordType.providerIntent.rawValue:
                    try await self.applyProviderIntent(record)
                case SyncRecordType.preferences.rawValue:
                    try await self.applyPreferences(record)
                case SyncRecordType.device.rawValue:
                    try await self.applyDevice(record)
                case SyncRecordType.accountSnapshot.rawValue:
                    try await self.applyAccountSnapshot(record)
                default:
                    break
                }
            } catch {
                await self.record(error: error)
            }
        }
    }

    private func shouldApplyServerRecord(_ server: CKRecord) -> Bool {
        guard let engine = self.engine,
              engine.state.pendingRecordZoneChanges.contains(.saveRecord(server.recordID)),
              let local = self.desiredRecords[server.recordID],
              server.recordType == SyncRecordType.providerIntent.rawValue
              || server.recordType == SyncRecordType.preferences.rawValue
        else {
            return true
        }
        let localValue = SyncConflictValue(
            value: local,
            editCount: self.editCount(local),
            modifiedAt: self.modifiedAt(local))
        let serverValue = SyncConflictValue(
            value: server,
            editCount: self.editCount(server),
            modifiedAt: self.modifiedAt(server))
        let winner = SyncConflictResolver.winner(local: localValue, server: serverValue)
        guard winner.value === local else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            self.desiredRecords.removeValue(forKey: server.recordID)
            return true
        }
        let rebased = Self.copyUserFields(from: local, onto: server)
        self.desiredRecords[server.recordID] = rebased
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        return false
    }

    private func applyProviderIntent(_ record: CKRecord) async throws {
        guard let payloadString = record["payload"] as? String else { return }
        let payload = try CanonicalSyncJSON.decode(ProviderIntentPayload.self, from: payloadString)
        let secrets = self.encryptedStringFields(record)
        let merged = try await MainActor.run {
            var config = self.settings.configSnapshot
            guard let local = config.providerConfig(for: payload.provider) else { return nil as ProviderConfig? }
            let merged = try payload.applying(
                to: local,
                secretFields: self.settings.iCloudSyncIncludeSecrets ? secrets : [:],
                canEnable: self.settings.canEnableProviderFromSync)
            config.setProviderConfig(merged)
            self.settings.applyExternalConfig(config, reason: "icloud", affectsBackgroundWork: true)
            // applyExternalConfig deliberately skips persistence (its other caller reloads FROM
            // the config file). Sync applies originate remotely, so the merge must reach disk —
            // the CLI and the next app launch read config.json, not our in-memory state.
            self.settings.schedulePersistConfig()
            return merged
        }
        guard let merged else { return }
        self.lastKnownProviderConfigs[payload.provider] = merged
        if payload.enabled == true, merged.enabled != true {
            self.persistenceEnvelope.suppressedEnableIntents.insert(payload.provider.rawValue)
        } else {
            self.persistenceEnvelope.suppressedEnableIntents.remove(payload.provider.rawValue)
        }
        self.persistEnvelope()
    }

    private func applyPreferences(_ record: CKRecord) async throws {
        guard let payloadString = record["payload"] as? String else { return }
        let payload = try CanonicalSyncJSON.decode(PreferencesSyncPayload.self, from: payloadString)
        self.lastKnownPreferences = payload.preferences
        await MainActor.run {
            self.settings.applySyncedPreferences(payload.preferences)
        }
    }

    private func applyDevice(_ record: CKRecord) async throws {
        guard let deviceID = record["deviceID"] as? String,
              let hostName = record["hostName"] as? String,
              let model = record["model"] as? String,
              let appVersion = record["appVersion"] as? String,
              let lastSeen = record["lastSeen"] as? Date
        else { return }
        let payload = DeviceSyncPayload(
            deviceID: deviceID,
            hostName: hostName,
            model: model,
            appVersion: appVersion,
            lastSeen: lastSeen,
            schemaVersion: self.schemaVersion(record))
        self.persistenceEnvelope.fleetDevices[record.recordID.recordName] = payload
        await MainActor.run { self.state.fleetDevices[record.recordID.recordName] = payload }
    }

    private func applyAccountSnapshot(_ record: CKRecord) async throws {
        guard !CloudSyncSnapshotMigration.hasInFlightSave(
            recordName: record.recordID.recordName,
            pendingSaveHashes: self.pendingSaveHashes)
        else { return }
        guard let providerRaw = record["provider"] as? String,
              let provider = ProviderInstanceID(rawValue: providerRaw),
              let deviceID = record["deviceID"] as? String,
              let accountKey = record["accountKey"] as? String,
              let fetchedAt = record["fetchedAt"] as? Date,
              let displayLabel = record.encryptedValues["displayLabel"] as? String,
              let usagePayload = record.encryptedValues["usagePayload"] as? String
        else { return }
        let usage = try CanonicalSyncJSON.decode(UsageSnapshot.self, from: usagePayload)
        let payload = AccountSnapshotSyncPayload(
            provider: provider,
            deviceID: deviceID,
            accountKey: accountKey,
            fetchedAt: fetchedAt,
            displayLabel: displayLabel,
            usage: usage,
            schemaVersion: self.schemaVersion(record))
        self.persistenceEnvelope.fleetSnapshots[record.recordID.recordName] = payload
        await MainActor.run { self.state.fleetSnapshots[record.recordID.recordName] = payload }
    }

    private func handleSaveFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine) async
    {
        switch failure.error.code {
        case .quotaExceeded:
            let retry = self.quotaRetryState.nextDelay(serverRetryAfter: failure.error.retryAfterSeconds)
            self.scheduleRetry(recordID: failure.record.recordID, after: retry)
        case .accountTemporarilyUnavailable:
            let retry = CloudSyncSnapshotMigration.retryDelay(for: failure.error) ?? 1
            self.scheduleRetry(recordID: failure.record.recordID, after: retry)
        case .serverRecordChanged:
            guard let server = failure.error.serverRecord else {
                await self.record(error: failure.error)
                self.pendingSaveHashes.removeValue(forKey: failure.record.recordID.recordName)
                return
            }
            await self.resolveConflict(with: server, syncEngine: syncEngine)
        case .zoneNotFound:
            self.recreateZoneAndRequeue(failure.record, syncEngine: syncEngine)
        default:
            let resetEncryptedData = (failure.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?
                .boolValue == true
            if resetEncryptedData {
                self.recreateZoneAndRequeue(failure.record, syncEngine: syncEngine)
            } else {
                await self.record(error: failure.error)
                self.abandonTerminalReplacementSave(failure)
            }
        }
    }

    private func recreateZoneAndRequeue(_ record: CKRecord, syncEngine: CKSyncEngine) {
        if self.desiredRecords[record.recordID] == nil {
            self.desiredRecords[record.recordID] = record
        }
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    private func scheduleRetry(recordID: CKRecord.ID, after delay: TimeInterval) {
        Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                await Task.yield()
                guard let self, let engine = await self.engine, await self.enabled else { return }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                try await engine.sendChanges(.init(scope: .recordIDs([recordID])))
            } catch {
                await self?.record(error: error)
            }
        }
    }

    private func resolveConflict(with server: CKRecord, syncEngine: CKSyncEngine) async {
        guard self.schemaVersion(server) <= CodexBarSyncSchema.currentVersion else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            self.desiredRecords.removeValue(forKey: server.recordID)
            self.pendingSaveHashes.removeValue(forKey: server.recordID.recordName)
            self.cacheSystemFields(server)
            self.persistEnvelope()
            await MainActor.run { self.state.status.needsAppUpdate = true }
            return
        }
        guard let local = self.desiredRecords[server.recordID] else { return }
        self.cacheSystemFields(server)
        let localValue = SyncConflictValue(
            value: local,
            editCount: self.editCount(local),
            modifiedAt: self.modifiedAt(local))
        let serverValue = SyncConflictValue(
            value: server,
            editCount: self.editCount(server),
            modifiedAt: self.modifiedAt(server))
        if SyncConflictResolver.winner(local: localValue, server: serverValue).value === local {
            self.desiredRecords[server.recordID] = Self.copyUserFields(from: local, onto: server)
            self.scheduleRetry(recordID: server.recordID, after: 0)
        } else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            self.desiredRecords.removeValue(forKey: server.recordID)
            self.pendingSaveHashes.removeValue(forKey: server.recordID.recordName)
            await self.applyFetchedRecords([server])
        }
    }

    private func scheduleFetchChanges(scopedToSyncZone: Bool) {
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            if scopedToSyncZone {
                await self.fetchChanges()
            } else {
                await self.fetchAllChanges()
            }
        }
    }

    private func fetchAllChanges() async {
        guard self.enabled, let engine = self.engine else { return }
        do {
            try await engine.fetchChanges()
            await MainActor.run { self.state.status.lastSuccessfulFetchAt = Date() }
        } catch {
            await self.record(error: error)
        }
    }

    private func startPeriodicFetchTimer() {
        self.periodicFetchTask?.cancel()
        self.periodicFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                await self?.fetchChanges()
            }
        }
    }

    private func stopEngine(clearPersistence: Bool) async {
        self.configPushTask?.cancel()
        self.snapshotPushTask?.cancel()
        self.periodicFetchTask?.cancel()
        if let engine = self.engine {
            await engine.cancelOperations()
        }
        self.engine = nil
        self.desiredRecords = [:]
        self.quotaRetryState.reset()
        self.pendingSaveHashes = [:]
        self.pendingSnapshots = []
        self.hasReconciledLiveSnapshots = false
        if clearPersistence {
            self.persistenceEnvelope = .init(stateSerialization: nil, encodedSystemFields: [:])
            self.lastSnapshotHashes = [:]
            self.skippedTerminalReplacementHashes = [:]
            self.didRehydrateFleetState = false
            try? self.persistence.delete()
            await MainActor.run {
                self.state.fleetDevices = [:]
                self.state.fleetSnapshots = [:]
            }
        }
    }

    func rehydrateFleetStateIfNeeded() async {
        guard !self.didRehydrateFleetState else { return }
        self.didRehydrateFleetState = true
        let devices = self.persistenceEnvelope.fleetDevices
        let snapshots = self.persistenceEnvelope.fleetSnapshots
        await MainActor.run {
            self.state.fleetDevices = devices
            self.state.fleetSnapshots = snapshots
        }
    }

    private func record(type: SyncRecordType, id: CKRecord.ID) -> CKRecord {
        if let data = self.persistenceEnvelope.encodedSystemFields[id.recordName],
           let record = CloudSyncPersistence.decodeRecord(from: data),
           record.recordType == type.rawValue
        {
            if let metadata = self.persistenceEnvelope.recordMetadata[id.recordName] {
                if let schemaVersion = metadata.schemaVersion {
                    record["schemaVersion"] = schemaVersion as CKRecordValue
                }
                if let editCount = metadata.editCount {
                    record["editCount"] = editCount as CKRecordValue
                }
                if let modifiedAt = metadata.modifiedAt {
                    record["modifiedAt"] = modifiedAt as CKRecordValue
                }
            }
            return record
        }
        return CKRecord(recordType: type.rawValue, recordID: id)
    }

    private func recordID(named recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
    }

    private func cacheSystemFields(_ record: CKRecord) {
        CloudSyncPersistence.cacheSystemFields(of: record, in: &self.persistenceEnvelope)
    }

    private func persistEnvelope() {
        do {
            try self.persistence.save(self.persistenceEnvelope)
        } catch {
            self.logger.error("Failed to persist CloudKit sync state: \(error)")
        }
    }

    private func encryptedStringFields(_ record: CKRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: record.encryptedValues.allKeys().compactMap { key in
            (record.encryptedValues[key] as? String).map { (key, $0) }
        })
    }

    static func copyUserFields(from source: CKRecord, onto server: CKRecord) -> CKRecord {
        // allKeys() includes encrypted field names, but CloudKit throws NSInvalidArgumentException
        // when an encrypted field goes through the plain subscript — every key must stay on the
        // API surface (plain vs encryptedValues) it was written with.
        let serverEncryptedKeys = Set(server.encryptedValues.allKeys())
        let sourceEncryptedKeys = Set(source.encryptedValues.allKeys())
        for key in server.allKeys() where !serverEncryptedKeys.contains(key) {
            server[key] = nil
        }
        for key in serverEncryptedKeys {
            server.encryptedValues[key] = nil
        }
        for key in source.allKeys() where !sourceEncryptedKeys.contains(key) {
            server[key] = source[key]
        }
        for key in sourceEncryptedKeys {
            server.encryptedValues[key] = source.encryptedValues[key]
        }
        return server
    }

    private func editCount(_ record: CKRecord) -> Int64 {
        (record["editCount"] as? NSNumber)?.int64Value ?? 0
    }

    private func modifiedAt(_ record: CKRecord) -> Date {
        record["modifiedAt"] as? Date ?? .distantPast
    }

    private func schemaVersion(_ record: CKRecord) -> Int {
        (record["schemaVersion"] as? NSNumber)?.intValue ?? 0
    }

    private func updateAvailability(_ availability: SyncAvailability) async {
        await MainActor.run { self.state.availability = availability }
    }

    private func record(error: Error) async {
        self.logger.error("iCloud sync failed: \(error)")
        await MainActor.run { self.state.status.lastError = error.localizedDescription }
    }

    private static func deviceModel() -> String {
        Sysctl.string("hw.model") ?? "unknown"
    }
}

extension CloudSyncEngine {
    /// Removes a device from the fleet on every Mac on the account. The current Mac re-registers
    /// itself the next time sync starts, which is why removal is offered for it too.
    func removeDevice(deviceID: String) async {
        guard let engine = self.engine else {
            await MainActor.run {
                self.state.status.lastError = L("Sync is not running yet. Try again in a moment.")
            }
            return
        }
        // The delete set is built from the fleet cache, so the cache has to be current: a usage
        // snapshot published since the last fetch would otherwise outlive the device record it
        // belongs to. A fetch that fails leaves no grounds to delete anything, and reports itself.
        guard await self.fetchChanges() else { return }
        let names = CloudSyncDeviceRemoval.recordNames(
            forDeviceID: deviceID,
            snapshots: self.persistenceEnvelope.fleetSnapshots)
        let recordIDs = CloudSyncSnapshotMigration.dropPushState(
            names,
            hashes: &self.lastSnapshotHashes,
            envelope: &self.persistenceEnvelope,
            desiredRecords: &self.desiredRecords,
            zoneID: Self.zoneID)
        self.rememberPendingRecordDeletes(names)
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
        do {
            try await engine.sendChanges(.init(scope: .recordIDs(recordIDs)))
        } catch {
            // The send never left this Mac, so stop tracking the names: nothing would drain them
            // from the pending set, which only the snapshot push requeues.
            self.forgetPendingRecordDeletes(names)
            await self.record(error: error)
        }
    }

    private func finishConfirmedSnapshotMigrations(
        savedRecordNames: [String],
        syncEngine: CKSyncEngine) async
    {
        let toDrop = CloudSyncSnapshotMigration.takeDeletes(
            forSavedRecordNames: savedRecordNames,
            pending: &self.persistenceEnvelope.pendingPredecessorDeletes,
            afterLiveSnapshotReconciliation: self.hasReconciledLiveSnapshots)
        CloudSyncSnapshotMigration.applyConfirmedSaveHashes(
            savedRecordNames: savedRecordNames,
            pendingSaveHashes: &self.pendingSaveHashes,
            lastSnapshotHashes: &self.lastSnapshotHashes)
        self.pendingSnapshots = CloudSyncSnapshotMigration.mergingPendingSnapshots(
            self.pendingSnapshots,
            with: CloudSyncSnapshotMigration.unpublishedFleetSnapshots(
                savedRecordNames: savedRecordNames,
                fleetSnapshots: self.persistenceEnvelope.fleetSnapshots,
                lastSnapshotHashes: self.lastSnapshotHashes))
        guard !toDrop.isEmpty else { return }
        let recordIDs = CloudSyncSnapshotMigration.dropPushState(
            toDrop,
            hashes: &self.lastSnapshotHashes,
            envelope: &self.persistenceEnvelope,
            desiredRecords: &self.desiredRecords,
            zoneID: Self.zoneID)
        for recordID in recordIDs {
            syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
        self.rememberPendingRecordDeletes(toDrop)
        // Unlike a device removal, the replacement snapshot is already saved, so the superseded
        // record is retired now rather than waiting for its delete to land.
        toDrop.forEach { self.persistenceEnvelope.fleetSnapshots.removeValue(forKey: $0) }
        await MainActor.run {
            toDrop.forEach { self.state.fleetSnapshots.removeValue(forKey: $0) }
        }
    }

    private func handleSentRecordDeletes(deletedIDs: [CKRecord.ID], failures: [CKRecord.ID: CKError]) async {
        var finished = Set(deletedIDs.map(\.recordName))
        finished.formUnion(CloudSyncSnapshotMigration.finishedFailedDeleteNames(failures))
        self.forgetPendingRecordDeletes(finished)
        await self.forgetFleetRecords(
            CloudSyncSnapshotMigration.confirmedDeletedNames(deletedIDs: deletedIDs, failures: failures))
        for error in CloudSyncSnapshotMigration.reportableFailedDeletes(failures) {
            await self.record(error: error)
        }
        let liveNames = CloudSyncSnapshotMigration.liveSnapshotRecordNames(
            pendingRecordNames: self.pendingSnapshots.map(\.recordName) +
                self.desiredRecords.keys.map(\.recordName),
            storedRecordNames: self.lastSnapshotHashes.keys)
        for recordID in CloudSyncSnapshotMigration.retryableFailedDeletes(failures, liveNames: liveNames) {
            self.rememberPendingRecordDeletes([recordID.recordName])
            let delay = failures[recordID].flatMap(CloudSyncSnapshotMigration.retryDelay(for:)) ?? 1
            self.scheduleDeleteRetry(recordID: recordID, after: delay)
        }
    }

    /// Drops every trace of records CloudKit no longer holds, so the Macs list and the fleet
    /// menu stop showing them. Both the local delete and a remote one land here.
    private func forgetFleetRecords(_ names: Set<String>) async {
        guard !names.isEmpty else { return }
        let names = names.union(CloudSyncDeviceRemoval.orphanedSnapshotNames(
            removedNames: names,
            snapshots: self.persistenceEnvelope.fleetSnapshots))
        for name in names {
            self.persistenceEnvelope.encodedSystemFields.removeValue(forKey: name)
            self.persistenceEnvelope.recordMetadata.removeValue(forKey: name)
            self.persistenceEnvelope.fleetDevices.removeValue(forKey: name)
            self.persistenceEnvelope.fleetSnapshots.removeValue(forKey: name)
        }
        await MainActor.run {
            for name in names {
                self.state.fleetDevices.removeValue(forKey: name)
                self.state.fleetSnapshots.removeValue(forKey: name)
            }
        }
        self.persistEnvelope()
    }

    private func rememberPendingRecordDeletes(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        self.persistenceEnvelope.pendingRecordDeletes.formUnion(names)
        self.persistEnvelope()
    }

    private func forgetPendingRecordDeletes(_ names: Set<String>) {
        let remaining = self.persistenceEnvelope.pendingRecordDeletes.subtracting(names)
        guard remaining != self.persistenceEnvelope.pendingRecordDeletes else { return }
        self.persistenceEnvelope.pendingRecordDeletes = remaining
        self.persistEnvelope()
    }

    private func cancelPendingRecordDeletes(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        self.forgetPendingRecordDeletes(names)
        guard let engine = self.engine else { return }
        engine.state.remove(pendingRecordZoneChanges: names.map { name in
            .deleteRecord(self.recordID(named: name))
        })
    }

    /// Deletes that never reached CloudKit, requeued once. Device Records are included, unlike
    /// in `retryableFailedDeletes`: a delete CloudKit rejected is abandoned, but one that was
    /// never attempted is still the removal the user asked for.
    private func requeuePendingRecordDeletes() {
        guard let engine = self.engine else { return }
        let liveNames = CloudSyncSnapshotMigration.liveSnapshotRecordNames(
            pendingRecordNames: self.pendingSnapshots.map(\.recordName) +
                self.desiredRecords.keys.map(\.recordName),
            storedRecordNames: self.lastSnapshotHashes.keys)
        let names = CloudSyncSnapshotMigration.pendingDeletesToRequeue(
            pendingDeletes: self.persistenceEnvelope.pendingRecordDeletes,
            liveNames: liveNames)
        for name in names {
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(self.recordID(named: name))])
        }
    }

    private func abandonTerminalReplacementSave(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave)
    {
        let name = failure.record.recordID.recordName
        let abandoned = CloudSyncSnapshotMigration.abandonedReplacementNames(
            failures: [name: failure.error],
            pendingReplacements: Set(self.persistenceEnvelope.pendingPredecessorDeletes.keys))
        if abandoned.contains(name) {
            self.persistenceEnvelope.pendingPredecessorDeletes.removeValue(forKey: name)
        }
        CloudSyncSnapshotMigration.applyTerminalSaveSkip(
            recordName: name,
            error: failure.error,
            pendingSaveHashes: &self.pendingSaveHashes,
            skippedTerminalReplacementHashes: &self.skippedTerminalReplacementHashes)
    }

    private func scheduleDeleteRetry(recordID: CKRecord.ID, after delay: TimeInterval) {
        Task { [weak self] in
            let originatingEngine = await self?.engine.map { ObjectIdentifier($0) }
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                await Task.yield()
                guard let self, await self.enabled else { return }
                guard await self.persistenceEnvelope.pendingRecordDeletes.contains(recordID.recordName) else {
                    return
                }
                guard let engine = await self.engine,
                      CloudSyncSnapshotMigration.shouldResumeDelayedRetry(
                          originatingEngine: originatingEngine,
                          currentEngine: ObjectIdentifier(engine))
                else { return }
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                try await engine.sendChanges(.init(scope: .recordIDs([recordID])))
            } catch is CancellationError {
                return
            } catch {
                await self?.record(error: error)
            }
        }
    }

    private func pushPendingSnapshots() async {
        guard let engine = self.engine else { return }
        guard !self.pendingSnapshots.isEmpty || !self.persistenceEnvelope.pendingRecordDeletes.isEmpty else {
            return
        }
        guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }
        do {
            let obsoleteNames = CloudSyncSnapshotMigration.obsoleteRecordNames(
                liveSnapshots: self.pendingSnapshots,
                hashes: self.lastSnapshotHashes,
                envelope: self.persistenceEnvelope)
            if !self.pendingSnapshots.isEmpty {
                CloudSyncSnapshotMigration.retainingObsoletePredecessors(
                    in: &self.persistenceEnvelope.pendingPredecessorDeletes,
                    obsoleteNames: obsoleteNames)
                self.cancelPendingRecordDeletes(
                    CloudSyncSnapshotMigration.cancelledPersistedDeletes(
                        pendingDeletes: self.persistenceEnvelope.pendingRecordDeletes,
                        liveNames: Set(self.pendingSnapshots.map(\.recordName))))
                self.hasReconciledLiveSnapshots = true
            }
            self.requeuePendingRecordDeletes()
            var stillPending: [AccountSnapshotSyncPayload] = []
            for payload in self.pendingSnapshots {
                let hash = try CanonicalSyncJSON.hash(payload)
                if self.skippedTerminalReplacementHashes[payload.recordName] == hash {
                    continue
                }
                let predecessors = CloudSyncSnapshotMigration.predecessorNames(
                    for: payload,
                    obsoleteNames: obsoleteNames)
                // Replace, don't union: a later live email-keyed snapshot must not stay queued
                // for delete after the slot-keyed save is confirmed.
                CloudSyncSnapshotMigration.assigningPredecessors(
                    predecessors,
                    to: payload.recordName,
                    pending: &self.persistenceEnvelope.pendingPredecessorDeletes)
                // Hashes are recorded only after CloudKit confirms a save.
                let alreadyPublished = self.lastSnapshotHashes[payload.recordName] == hash
                if alreadyPublished {
                    if !predecessors.isEmpty {
                        await self.finishConfirmedSnapshotMigrations(
                            savedRecordNames: [payload.recordName],
                            syncEngine: engine)
                    }
                    continue
                }
                if CloudSyncSnapshotMigration.hasInFlightSave(
                    recordName: payload.recordName,
                    pendingSaveHashes: self.pendingSaveHashes)
                {
                    self.persistenceEnvelope.fleetSnapshots[payload.recordName] = payload
                    stillPending.append(payload)
                    continue
                }
                let recordID = self.recordID(named: payload.recordName)
                let record = self.record(type: .accountSnapshot, id: recordID)
                record["schemaVersion"] = payload.schemaVersion as CKRecordValue
                record["provider"] = payload.provider.rawValue as CKRecordValue
                record["deviceID"] = payload.deviceID as CKRecordValue
                record["accountKey"] = payload.accountKey as CKRecordValue
                record["fetchedAt"] = payload.fetchedAt as CKRecordValue
                record.encryptedValues["displayLabel"] = payload.displayLabel as CKRecordValue
                record.encryptedValues["usagePayload"] = try CanonicalSyncJSON.string(payload.usage) as CKRecordValue
                self.desiredRecords[recordID] = record
                self.persistenceEnvelope.fleetSnapshots[payload.recordName] = payload
                self.skippedTerminalReplacementHashes.removeValue(forKey: payload.recordName)
                self.pendingSaveHashes[payload.recordName] = hash
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
            self.pendingSnapshots = stillPending
            self.lastSnapshotPushAt = Date()
            self.persistEnvelope()
        } catch {
            await self.record(error: error)
        }
    }
}
