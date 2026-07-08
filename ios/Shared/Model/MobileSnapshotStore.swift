import Foundation

/// Identifiers shared by the iOS app, widget extension, and Live Activity.
public enum MobileAppGroup {
    /// App Group shared between the iOS app and its extensions. Must match the value in every
    /// target's `.entitlements` file and `ios/project.yml`.
    public static let identifier = "group.com.steipete.codexbar.ios"

    public static let snapshotFilename = "mobile-snapshot.json"
    public static let metadataFilename = "mobile-sync-metadata.json"
}

/// How the most recent snapshot reached this device.
public enum SnapshotSource: String, Codable, Sendable {
    case lan
    case cloudKit
    case manual
    case unknown

    public var displayName: String {
        switch self {
        case .lan: "Local network"
        case .cloudKit: "iCloud"
        case .manual: "Manual"
        case .unknown: "—"
        }
    }
}

public struct SyncMetadata: Codable, Sendable {
    public var source: SnapshotSource
    public var receivedAt: Date
    public var senderDeviceName: String?
    public var snapshotGeneratedAt: Date?

    public init(
        source: SnapshotSource,
        receivedAt: Date,
        senderDeviceName: String? = nil,
        snapshotGeneratedAt: Date? = nil)
    {
        self.source = source
        self.receivedAt = receivedAt
        self.senderDeviceName = senderDeviceName
        self.snapshotGeneratedAt = snapshotGeneratedAt
    }
}

/// Reads and writes the mirrored snapshot in the shared App Group container so the app,
/// widget, and Live Activity all see the same data. Falls back to the app sandbox when the
/// App Group container is unavailable (e.g. unsigned simulator builds without the entitlement).
public enum MobileSnapshotStore {
    public static func loadSnapshot() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: self.snapshotURL()) else { return nil }
        return try? SnapshotCoding.decoder.decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    public static func save(_ snapshot: WidgetSnapshot, metadata: SyncMetadata) -> Bool {
        do {
            let data = try SnapshotCoding.encoder.encode(snapshot)
            try data.write(to: self.snapshotURL(), options: [.atomic])
            let metaData = try SnapshotCoding.encoder.encode(metadata)
            try metaData.write(to: self.metadataURL(), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    public static func loadMetadata() -> SyncMetadata? {
        guard let data = try? Data(contentsOf: self.metadataURL()) else { return nil }
        return try? SnapshotCoding.decoder.decode(SyncMetadata.self, from: data)
    }

    public static func containerURL() -> URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MobileAppGroup.identifier) {
            return group
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("CodexBarMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func snapshotURL() -> URL {
        self.containerURL().appendingPathComponent(MobileAppGroup.snapshotFilename, isDirectory: false)
    }

    private static func metadataURL() -> URL {
        self.containerURL().appendingPathComponent(MobileAppGroup.metadataFilename, isDirectory: false)
    }
}
