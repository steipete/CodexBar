import CryptoKit
import Foundation

/// Authenticated encryption for the LAN channel. After the phone sends a random handshake nonce,
/// both sides derive a per-session key from the shared pairing key, and every snapshot frame is
/// sealed with AES-GCM. GCM gives us both confidentiality (others on the LAN can't read it) and
/// authenticity (only a Mac holding the pairing key can produce a frame the phone can open — which
/// is how the phone knows it reached the *right* Mac, not a stranger's).
public enum SyncCrypto {
    private static let info = Data("codexbar-sync-v1".utf8)

    /// Derive the per-session key from the long-lived pairing key and the handshake nonce.
    public static func sessionKey(pairKey: SymmetricKey, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey,
            salt: nonce,
            info: self.info,
            outputByteCount: 32)
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    public static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    public static func randomNonce(byteCount: Int = 16) -> Data {
        Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
    }
}

/// Framed messages over the LAN socket. The `hello` frame is plaintext (carries only a random
/// nonce); every subsequent `data` frame is an AES-GCM box of a `SyncEnvelope` JSON.
public enum SyncFrame {
    /// Phone → Mac: opens the session with a fresh nonce.
    public struct Hello: Codable, Sendable {
        public let v: Int
        public let nonce: String // base64
        public init(nonce: Data) {
            self.v = 1
            self.nonce = nonce.base64EncodedString()
        }

        public var nonceData: Data? { Data(base64Encoded: self.nonce) }
    }

    public static func encodeHello(_ hello: Hello) throws -> Data {
        try JSONEncoder().encode(hello)
    }

    public static func decodeHello(_ data: Data) throws -> Hello {
        try JSONDecoder().decode(Hello.self, from: data)
    }
}
