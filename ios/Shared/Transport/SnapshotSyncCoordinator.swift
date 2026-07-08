import Foundation
import Observation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Central sync brain for the iOS app. Owns the LAN fast-path and the CloudKit backbone,
/// merges incoming snapshots (newest `generatedAt` wins), persists to the shared App Group,
/// and reloads widget timelines. Observable so SwiftUI views react to updates.
@MainActor
@Observable
public final class SnapshotSyncCoordinator {
    public enum LANStatus: Sendable {
        case idle
        case searching
        case connected
    }

    public private(set) var snapshot: WidgetSnapshot?
    public private(set) var metadata: SyncMetadata?
    public private(set) var lanStatus: LANStatus = .idle
    public private(set) var iCloudAvailable = false

    /// User settings (mirrored into UserDefaults so extensions can read them).
    public var lanEnabled: Bool {
        didSet { self.defaults.set(self.lanEnabled, forKey: Self.lanEnabledKey); self.applyTransportState() }
    }

    public var iCloudEnabled: Bool {
        didSet { self.defaults.set(self.iCloudEnabled, forKey: Self.iCloudEnabledKey); self.applyTransportState() }
    }

    /// App-layer hook invoked (on the main actor) whenever a newer snapshot is ingested. The app
    /// uses this to refresh running Live Activities without the shared module depending on ActivityKit.
    public var onSnapshotUpdate: ((WidgetSnapshot) -> Void)?

    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "SyncCoordinator")
    private let lan = LANSubscriber()
    private let cloudKit = CloudKitSnapshotClient()
    private let defaults: UserDefaults
    private var started = false

    private static let lanEnabledKey = "sync.lanEnabled"
    private static let iCloudEnabledKey = "sync.iCloudEnabled"

    public init() {
        self.defaults = UserDefaults(suiteName: MobileAppGroup.identifier) ?? .standard
        self.lanEnabled = self.defaults.object(forKey: Self.lanEnabledKey) as? Bool ?? true
        self.iCloudEnabled = self.defaults.object(forKey: Self.iCloudEnabledKey) as? Bool ?? true
        self.snapshot = MobileSnapshotStore.loadSnapshot()
        self.metadata = MobileSnapshotStore.loadMetadata()
    }

    public func start() {
        guard !self.started else { return }
        self.started = true
        #if DEBUG
        // Seed sample data only for screenshots (`-seed`). Otherwise the app shows the real
        // "Waiting for CodexBar" state until a live snapshot arrives — never fake numbers.
        if self.snapshot == nil, CommandLine.arguments.contains("-seed") {
            self.ingest(SyncEnvelope(senderDeviceName: "Sample Mac", snapshot: SampleData.snapshot()), source: .manual)
        }
        #endif
        self.applyTransportState()
        Task { await self.refreshCloudKit() }
    }

    /// Called when the app returns to the foreground.
    public func onForeground() {
        self.applyTransportState()
        Task { await self.refreshCloudKit() }
    }

    /// Pull-to-refresh: force a CloudKit fetch.
    public func manualRefresh() async {
        await self.refreshCloudKit()
    }

    // MARK: - Transport wiring

    private func applyTransportState() {
        guard self.started else { return }
        if self.lanEnabled {
            self.lanStatus = .searching
            self.lan.start(
                onEnvelope: { [weak self] envelope in
                    Task { @MainActor in self?.ingest(envelope, source: .lan) }
                },
                onConnectedChange: { [weak self] connected in
                    Task { @MainActor in self?.lanStatus = connected ? .connected : .searching }
                })
        } else {
            self.lan.stop()
            self.lanStatus = .idle
        }
    }

    private func refreshCloudKit() async {
        guard self.iCloudEnabled else { self.iCloudAvailable = false; return }
        self.iCloudAvailable = await self.cloudKit.accountAvailable()
        guard self.iCloudAvailable else { return }
        await self.cloudKit.ensureSubscription()
        if let envelope = await self.cloudKit.fetchLatest() {
            self.ingest(envelope, source: .cloudKit)
        }
    }

    // MARK: - Ingestion

    /// Accept an envelope only if it is newer than what we already have.
    func ingest(_ envelope: SyncEnvelope, source: SnapshotSource) {
        if let current = self.snapshot?.generatedAt,
           envelope.snapshot.generatedAt <= current
        {
            self.log.debug("ignoring stale \(source.rawValue, privacy: .public) snapshot")
            return
        }
        let metadata = SyncMetadata(
            source: source,
            receivedAt: Date(),
            senderDeviceName: envelope.senderDeviceName,
            snapshotGeneratedAt: envelope.snapshot.generatedAt)
        self.snapshot = envelope.snapshot
        self.metadata = metadata
        MobileSnapshotStore.save(envelope.snapshot, metadata: metadata)
        self.reloadWidgets()
        self.onSnapshotUpdate?(envelope.snapshot)
        self.log.info("ingested snapshot via \(source.rawValue, privacy: .public)")
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
