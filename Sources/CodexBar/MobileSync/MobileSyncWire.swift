import CodexBarCore
import Foundation

/// Wire contract for the iPhone companion app. Mirrors `ios/Shared/Transport/SyncEnvelope.swift`
/// on the iOS side — both encode/decode the same JSON, so keep the two in sync.
enum MobileSyncWire {
    static let schemaVersion = 1

    // LAN (Bonjour + Network.framework)
    static let bonjourServiceType = "_codexbar-sync._tcp"
    static let lengthPrefixByteCount = 4
    static let maxMessageByteCount = 2 * 1024 * 1024

    // CloudKit (user's private database — no server)
    static let cloudKitContainerIdentifier = "iCloud.com.steipete.codexbar"
    static let cloudKitRecordType = "WidgetSnapshot"
    static let cloudKitRecordName = "latest-snapshot"

    enum CloudKitField {
        static let payload = "payload"
        static let senderDeviceName = "senderDeviceName"
        static let generatedAt = "generatedAt"
        static let schemaVersion = "schemaVersion"
    }

    /// Prefixes a payload with a 4-byte big-endian length for stream framing.
    static func framed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: Self.lengthPrefixByteCount)
        out.append(payload)
        return out
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// The envelope sent to iPhones. Wraps the same `WidgetSnapshot` the macOS widget already uses.
struct MobileSyncEnvelope: Encodable {
    let schemaVersion: Int
    let senderDeviceName: String
    let snapshot: WidgetSnapshot

    init(snapshot: WidgetSnapshot, senderDeviceName: String) {
        self.schemaVersion = MobileSyncWire.schemaVersion
        self.senderDeviceName = senderDeviceName
        self.snapshot = snapshot
    }

    func encoded() throws -> Data {
        try MobileSyncWire.encoder.encode(self)
    }
}
