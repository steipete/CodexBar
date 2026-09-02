import CryptoKit
import Foundation

/// How a Mac identifies itself to the Fleet. See `docs/adr/0001-stable-device-identity.md`.
enum CloudSyncDeviceIdentity {
    /// A persisted Device Identifier always wins, so a Fleet created before stable identity keeps
    /// addressing its existing Device Records. Only a Mac with none derives one, which is what stops
    /// a reinstall from stranding the previous Device Record.
    static func resolve(persisted: String?, hardwareUUID: String?) -> String {
        if let persisted, !persisted.isEmpty {
            return persisted
        }
        guard let hardwareUUID, !hardwareUUID.isEmpty else {
            return UUID().uuidString.lowercased()
        }
        return self.derive(from: hardwareUUID)
    }

    /// The Mac's hardware UUID, which survives reinstalling CodexBar and macOS.
    static func hardwareUUID() -> String? {
        Sysctl.string("kern.uuid")
    }

    /// Hashed so the raw hardware identifier never reaches CloudKit, and shaped as a UUID because
    /// every Device Identifier issued before this change is one.
    private static func derive(from hardwareUUID: String) -> String {
        SHA256.hash(data: Data(hardwareUUID.utf8))
            .withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)).uuidString.lowercased() }
    }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(bytes: bytes, encoding: .utf8)
    }
}
