import CryptoKit
import Foundation

/// A Mac's secret identity. Lives on the Mac only (Keychain / config). The `deviceID` is public
/// (advertised in Bonjour TXT so a phone can recognize a paired Mac); `keyBase64` is the 256-bit
/// shared secret, transferred out-of-band via the pairing QR/code and never sent over the wire.
public struct MacIdentity: Codable, Sendable {
    public let deviceID: String
    public let keyBase64: String
    public var name: String

    public init(deviceID: String, keyBase64: String, name: String) {
        self.deviceID = deviceID
        self.keyBase64 = keyBase64
        self.name = name
    }

    public static func generate(name: String) -> MacIdentity {
        let id = Data((0..<12).map { _ in UInt8.random(in: 0...255) }).base64URLEncodedString()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        return MacIdentity(deviceID: id, keyBase64: keyData.base64EncodedString(), name: name)
    }

    public var symmetricKey: SymmetricKey? {
        Data(base64Encoded: self.keyBase64).map { SymmetricKey(data: $0) }
    }

    /// The out-of-band pairing code the phone scans or types.
    public var pairingCode: String {
        PairingCode.encode(deviceID: self.deviceID, keyBase64: self.keyBase64, name: self.name)
    }
}

/// A Mac the phone has paired with (stored in the iOS Keychain). Mirror of the trusted half of
/// `MacIdentity`.
public struct PairedMac: Codable, Sendable, Identifiable, Equatable {
    public let deviceID: String
    public let keyBase64: String
    public var name: String

    public var id: String { self.deviceID }

    public init(deviceID: String, keyBase64: String, name: String) {
        self.deviceID = deviceID
        self.keyBase64 = keyBase64
        self.name = name
    }

    public var symmetricKey: SymmetricKey? {
        Data(base64Encoded: self.keyBase64).map { SymmetricKey(data: $0) }
    }
}

public enum PairingCodeError: Error {
    case invalid
}

/// Versioned, base64url-encoded pairing payload — pattern borrowed from agent-activity's `aa1.` code.
/// Format: `cbp1.` + base64url(JSON `{v, id, k, n}`). Carries the 256-bit key, so it is a *secret* —
/// only render it in the pairing UI, never log or transmit it.
public enum PairingCode {
    public static let prefix = "cbp1."

    private struct Payload: Codable {
        let v: Int
        let id: String
        let k: String
        let n: String
    }

    public static func encode(deviceID: String, keyBase64: String, name: String) -> String {
        let payload = Payload(v: 1, id: deviceID, k: keyBase64, n: name)
        let json = (try? JSONEncoder().encode(payload)) ?? Data()
        return self.prefix + json.base64URLEncodedString()
    }

    public static func decode(_ code: String) throws -> PairedMac {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(self.prefix),
              let data = Data(base64URLEncoded: String(trimmed.dropFirst(self.prefix.count))),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == 1, !payload.id.isEmpty, !payload.k.isEmpty,
              Data(base64Encoded: payload.k)?.count == 32
        else {
            throw PairingCodeError.invalid
        }
        return PairedMac(deviceID: payload.id, keyBase64: payload.k, name: payload.n)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
