import CryptoKit
import Foundation
import Security

// MARK: - OpenClaw Gateway Pairing

/// Manages pairing state between CodexBar and an OpenClaw gateway.
///
/// On first inject: reads the gateway token, verifies it, and stores
/// the pairing info (port, token hash, timestamp) in the Keychain.
/// Subsequent injects use the stored pairing for faster connection.
///
/// Security: Only a SHA-256 hash of the token is stored in Keychain —
/// the actual token is always read fresh from disk at connect time.
public final class OpenClawPairing: Sendable {

    // MARK: - Types

    public struct PairingInfo: Codable, Sendable {
        public let port: Int
        public let tokenHash: String  // SHA-256 of gateway token
        public let pairedAt: Date
        public let gatewayVersion: String?

        public init(port: Int, tokenHash: String, pairedAt: Date = Date(), gatewayVersion: String? = nil) {
            self.port = port
            self.tokenHash = tokenHash
            self.pairedAt = pairedAt
            self.gatewayVersion = gatewayVersion
        }
    }

    public enum PairingError: Error, LocalizedError, Sendable {
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case tokenChanged
        case notPaired

        public var errorDescription: String? {
            switch self {
            case .keychainWriteFailed(let status):
                return "Failed to save pairing to Keychain (status \(status))"
            case .keychainReadFailed(let status):
                return "Failed to read pairing from Keychain (status \(status))"
            case .tokenChanged:
                return "Gateway token has changed since last pairing — re-pair required"
            case .notPaired:
                return "No existing pairing found"
            }
        }
    }

    // MARK: - Constants

    private static let keychainService = "com.codexbar.openclaw-pairing"
    private static let keychainAccount = "gateway-pairing"

    // MARK: - Public API

    /// Check if a valid pairing exists and the token hasn't changed.
    public static func loadPairing() -> PairingInfo? {
        guard let data = readFromKeychain() else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    /// Verify the stored pairing against the current gateway token.
    /// Returns the pairing if valid, nil if token changed or no pairing exists.
    public static func verifyPairing() -> PairingInfo? {
        guard let pairing = loadPairing() else { return nil }

        // Read current token and compare hash
        guard let currentToken = try? OpenClawGatewayClient.readGatewayToken() else {
            return nil
        }

        let currentHash = sha256Hex(currentToken)
        guard currentHash == pairing.tokenHash else {
            // Token changed — pairing is stale
            return nil
        }

        return pairing
    }

    /// Create or update pairing for the given port.
    /// Reads the current gateway token and stores a hash in Keychain.
    @discardableResult
    public static func pair(port: Int, gatewayVersion: String? = nil) throws -> PairingInfo {
        let token = try OpenClawGatewayClient.readGatewayToken()
        let hash = sha256Hex(token)

        let info = PairingInfo(
            port: port,
            tokenHash: hash,
            pairedAt: Date(),
            gatewayVersion: gatewayVersion)

        let data = try JSONEncoder().encode(info)
        try saveToKeychain(data: data)

        return info
    }

    /// Remove stored pairing from Keychain.
    public static func unpair() {
        deleteFromKeychain()
    }

    // MARK: - Auto-Pair

    /// Auto-pair on first inject: verify gateway token is readable, then store pairing.
    /// If already paired and token matches, returns existing pairing.
    /// If not paired or token changed, creates a new pairing.
    public static func ensurePaired(port: Int) throws -> PairingInfo {
        // Check existing pairing
        if let existing = verifyPairing(), existing.port == port {
            return existing
        }

        // New pairing needed
        return try pair(port: port)
    }

    // MARK: - Keychain Helpers

    private static func readFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return data
    }

    private static func saveToKeychain(data: Data) throws {
        // Delete existing first
        deleteFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PairingError.keychainWriteFailed(status)
        }
    }

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Hashing

    private static func sha256Hex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
