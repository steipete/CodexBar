import Foundation

/// Wire envelope exchanged over LAN and CloudKit. The macOS publisher and the iOS
/// subscriber both encode/decode this exact shape.
public struct SyncEnvelope: Codable, Sendable {
    /// Bumped when the wire format changes incompatibly. Receivers ignore newer majors.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let senderDeviceName: String
    public let snapshot: WidgetSnapshot

    public init(
        schemaVersion: Int = SyncEnvelope.currentSchemaVersion,
        senderDeviceName: String,
        snapshot: WidgetSnapshot)
    {
        self.schemaVersion = schemaVersion
        self.senderDeviceName = senderDeviceName
        self.snapshot = snapshot
    }

    public func encoded() throws -> Data {
        try SnapshotCoding.encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> SyncEnvelope {
        try SnapshotCoding.decoder.decode(SyncEnvelope.self, from: data)
    }
}

/// Constants shared between the macOS LAN publisher and the iOS LAN subscriber.
/// Keep in sync with the macOS-side `MobileLANConstants` mirror.
public enum LANSync {
    /// Bonjour service type CodexBar advertises on the local network.
    public static let bonjourServiceType = "_codexbar-sync._tcp"
    public static let bonjourDomain = "local."

    /// TCP framing: a 4-byte big-endian unsigned length prefix followed by the JSON payload.
    public static let lengthPrefixByteCount = 4

    /// Hard cap on a single framed message (2 MB) to reject malformed/hostile length prefixes.
    public static let maxMessageByteCount = 2 * 1024 * 1024

    public static func framed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: LANSync.lengthPrefixByteCount)
        out.append(payload)
        return out
    }
}

/// CloudKit record/zone identifiers shared by publisher and subscriber.
public enum CloudKitSync {
    /// The private-database CloudKit container. Must match the container entitlement in every target.
    public static let containerIdentifier = "iCloud.com.steipete.codexbar"
    public static let recordType = "WidgetSnapshot"
    /// A single well-known record holds the latest snapshot (last-writer-wins).
    public static let recordName = "latest-snapshot"
    public static let subscriptionID = "widget-snapshot-changes"

    public enum Field {
        public static let payload = "payload"
        public static let senderDeviceName = "senderDeviceName"
        public static let generatedAt = "generatedAt"
        public static let schemaVersion = "schemaVersion"
    }
}
