import CloudKit
import CodexBarCore
import Foundation
import Network
import OSLog

/// Publishes the aggregated `WidgetSnapshot` to the CodexBar iPhone companion app.
///
/// Two serverless transports, both 100% user-managed:
/// - **LAN**: advertises `_codexbar-sync._tcp` over Bonjour and streams the latest snapshot to any
///   iPhone on the same network — instant, offline, zero configuration.
/// - **iCloud**: writes the snapshot to the user's *private* CloudKit database so widgets, the Lock
///   Screen, and Live Activities stay fresh when the phone is away from the Mac's network.
///
/// Opt-in: does nothing unless `UserDefaults.standard.bool(forKey: "mobileSyncEnabled")` is true, so
/// existing users are unaffected. LAN advertising requires the `com.apple.security.network.server`
/// entitlement; CloudKit requires the iCloud/CloudKit entitlement and container (see `ios/README.md`).
final class MobileSyncPublisher: @unchecked Sendable {
    static let shared = MobileSyncPublisher()

    // UserDefaults keys (read directly to avoid threading a new flag through the whole SettingsStore).
    static let enabledKey = "mobileSyncEnabled"
    static let lanEnabledKey = "mobileSyncLANEnabled"
    static let cloudKitEnabledKey = "mobileSyncCloudKitEnabled"

    private let log = Logger(subsystem: "com.steipete.codexbar", category: "MobileSync")
    private let queue = DispatchQueue(label: "com.steipete.codexbar.mobilesync")
    private let defaults: UserDefaults
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var latestFramed: Data?
    private var cachedContainer: CKContainer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var isEnabled: Bool { self.defaults.bool(forKey: Self.enabledKey) }
    private var lanEnabled: Bool { self.defaults.object(forKey: Self.lanEnabledKey) as? Bool ?? true }
    private var cloudKitEnabled: Bool { self.defaults.object(forKey: Self.cloudKitEnabledKey) as? Bool ?? true }

    private var senderDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Entry point called from the widget-snapshot persist path.
    func handleSnapshot(_ snapshot: WidgetSnapshot) {
        guard self.isEnabled else {
            self.queue.async { self.shutdownLAN() }
            return
        }
        let envelope = MobileSyncEnvelope(snapshot: snapshot, senderDeviceName: self.senderDeviceName)
        guard let payload = try? envelope.encoded() else { return }
        let framed = MobileSyncWire.framed(payload)
        self.queue.async {
            self.latestFramed = framed
            if self.lanEnabled {
                self.startLANIfNeeded()
                self.broadcast(framed)
            } else {
                self.shutdownLAN()
            }
        }
        if self.cloudKitEnabled { self.publishToCloudKit(payload: payload, snapshot: snapshot) }
    }

    // MARK: - LAN

    private func startLANIfNeeded() {
        guard self.listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(type: MobileSyncWire.bonjourServiceType)
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.log.error("LAN listener failed: \(error.localizedDescription, privacy: .public)")
                    self?.queue.async { self?.shutdownLAN() }
                }
            }
            self.listener = listener
            listener.start(queue: self.queue)
            self.log.info("LAN listener advertising \(MobileSyncWire.bonjourServiceType, privacy: .public)")
        } catch {
            self.log.error("failed to start LAN listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        self.connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                switch state {
                case .ready:
                    if let framed = self?.latestFramed {
                        connection.send(content: framed, completion: .contentProcessed { _ in })
                    }
                case .failed, .cancelled:
                    self?.connections[key] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: self.queue)
    }

    private func broadcast(_ framed: Data) {
        for connection in self.connections.values where connection.state == .ready {
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    private func shutdownLAN() {
        self.listener?.cancel()
        self.listener = nil
        for connection in self.connections.values { connection.cancel() }
        self.connections.removeAll()
    }

    // MARK: - CloudKit

    /// Gated on an iCloud identity because `CKContainer(identifier:)` traps without the entitlement.
    private var cloudKitAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    private func container() -> CKContainer? {
        guard self.cloudKitAvailable else { return nil }
        if let cachedContainer { return cachedContainer }
        let created = CKContainer(identifier: MobileSyncWire.cloudKitContainerIdentifier)
        self.cachedContainer = created
        return created
    }

    private func publishToCloudKit(payload: Data, snapshot: WidgetSnapshot) {
        guard let database = self.container()?.privateCloudDatabase else { return }
        let recordID = CKRecord.ID(recordName: MobileSyncWire.cloudKitRecordName)
        let deviceName = self.senderDeviceName
        Task {
            do {
                let record = (try? await database.record(for: recordID))
                    ?? CKRecord(recordType: MobileSyncWire.cloudKitRecordType, recordID: recordID)
                record[MobileSyncWire.CloudKitField.payload] = payload as CKRecordValue
                record[MobileSyncWire.CloudKitField.senderDeviceName] = deviceName as CKRecordValue
                record[MobileSyncWire.CloudKitField.generatedAt] = snapshot.generatedAt as CKRecordValue
                record[MobileSyncWire.CloudKitField.schemaVersion] = MobileSyncWire.schemaVersion as CKRecordValue
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
                self.log.info("published snapshot to CloudKit")
            } catch {
                self.log.error("CloudKit publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
