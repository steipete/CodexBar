import CloudKit
import Foundation
import OSLog

/// Reads and writes the latest snapshot to the user's *private* CloudKit database.
///
/// This is the serverless, always-on backbone: no server, no CloudFlare Worker — just the
/// user's own iCloud. It is the only transport that keeps widgets, the Lock Screen, and Live
/// Activities fresh while the app is backgrounded and off the local network.
///
/// `CKContainer(identifier:)` **traps** if the process lacks the `com.apple.developer.icloud-services`
/// entitlement, so the container is created lazily and only after confirming the entitlement is
/// present. Unsigned/simulator builds without the capability simply skip CloudKit and fall back to
/// LAN + the last cached snapshot.
public final class CloudKitSnapshotClient: @unchecked Sendable {
    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "CloudKit")
    private let containerIdentifier: String
    private let recordID = CKRecord.ID(recordName: CloudKitSync.recordName)
    private let lock = NSLock()
    private var cachedContainer: CKContainer?

    public init(containerIdentifier: String = CloudKitSync.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public enum CloudKitSyncError: Error {
        case unavailable
    }

    /// Whether CloudKit is safe to touch. `CKContainer(identifier:)` **traps** (crashes) without the
    /// `com.apple.developer.icloud-services` entitlement, and iOS exposes no public entitlement reader.
    /// Gating on the iCloud identity alone is insufficient: a real device signed into iCloud has a
    /// non-nil token even when the app was signed *without* the CloudKit entitlement (e.g. this
    /// unsigned/wildcard test build) — which is exactly the launch crash we must avoid.
    ///
    /// So we read the entitlement directly from the app's embedded provisioning profile (present in
    /// development / ad-hoc device builds) and only proceed when it actually grants CloudKit *and*
    /// an iCloud account is available.
    public static var isAvailable: Bool {
        self.hasCloudKitEntitlement && FileManager.default.ubiquityIdentityToken != nil
    }

    /// Parses `embedded.mobileprovision` for a CloudKit grant. Returns false when there is no
    /// profile (Simulator, or an App Store build that strips it) — conservative by design: better to
    /// skip CloudKit than to crash. Signed dev/ad-hoc builds with the entitlement return true.
    static let hasCloudKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The file is CMS-signed DER; the entitlements plist is embedded as plain text.
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>")
        else { return false }
        let plistText = String(raw[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        else { return false }
        return services.contains { $0 == "CloudKit" || $0 == "CloudKit-Anonymous" }
    }()

    private var container: CKContainer? {
        guard Self.isAvailable else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cachedContainer { return cachedContainer }
        let created = CKContainer(identifier: self.containerIdentifier)
        self.cachedContainer = created
        return created
    }

    private var database: CKDatabase? { self.container?.privateCloudDatabase }

    /// Returns true when the user has a usable iCloud account for the private database.
    public func accountAvailable() async -> Bool {
        guard let container else { return false }
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: - Publish (primarily macOS)

    public func publish(_ envelope: SyncEnvelope) async throws {
        guard let database, await self.accountAvailable() else { throw CloudKitSyncError.unavailable }
        let payload = try envelope.encoded()
        let record: CKRecord
        if let existing = try? await database.record(for: self.recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CloudKitSync.recordType, recordID: self.recordID)
        }
        record[CloudKitSync.Field.payload] = payload as CKRecordValue
        record[CloudKitSync.Field.senderDeviceName] = envelope.senderDeviceName as CKRecordValue
        record[CloudKitSync.Field.generatedAt] = envelope.snapshot.generatedAt as CKRecordValue
        record[CloudKitSync.Field.schemaVersion] = envelope.schemaVersion as CKRecordValue
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        self.log.info("published snapshot to CloudKit")
    }

    // MARK: - Fetch (iOS app + extensions)

    public func fetchLatest() async -> SyncEnvelope? {
        guard let database, await self.accountAvailable() else { return nil }
        do {
            let record = try await database.record(for: self.recordID)
            guard let payload = record[CloudKitSync.Field.payload] as? Data else { return nil }
            return try SyncEnvelope.decoded(from: payload)
        } catch {
            self.log.error("fetchLatest failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Registers a silent-push subscription so the app is woken when the Mac writes a new snapshot.
    /// Safe to call repeatedly; CloudKit dedupes by subscription ID.
    public func ensureSubscription() async {
        guard let database, await self.accountAvailable() else { return }
        let subscription = CKQuerySubscription(
            recordType: CloudKitSync.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: CloudKitSync.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            self.log.info("CloudKit subscription ensured")
        } catch {
            self.log.debug("ensureSubscription: \(error.localizedDescription, privacy: .public)")
        }
    }
}
