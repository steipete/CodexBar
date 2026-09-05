import Foundation
#if os(macOS)
import Security
#endif

/// Reads the Muse Code CLI login. Subscription usage is minted with the device-code
/// `dca:` access token, not a dashboard `LLM_` / Muse-minted `LLM|` inference key.
public enum MuseCredentials {
    public static let keychainService = "ai.meta.dev.credentials"
    public static let keychainAccount = "meta"
    public static let authPathEnvironmentKey = "MUSE_AUTH_PATH"

    private static let accessTokenPrefix = "dca:"

    public static func hasLogin(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool
    {
        if self.authFileRecord(environment: environment, homeDirectory: homeDirectory) != nil {
            return true
        }
        return (try? self.keychainAccessToken()) != nil
    }

    public static func accessToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String
    {
        let authFile = self.authFileRecord(environment: environment, homeDirectory: homeDirectory)
        if let token = authFile?.accessToken {
            return token
        }
        do {
            if let token = try self.keychainAccessToken() {
                return token
            }
        } catch MuseUsageError.keychainUnavailable {
            if authFile != nil { throw MuseUsageError.keychainUnavailable }
        }
        throw MuseUsageError.missingCredentials
    }

    static func accessToken(fromKeychainPayload data: Data) throws -> String {
        let payload: KeychainPayload
        do {
            payload = try JSONDecoder().decode(KeychainPayload.self, from: data)
        } catch {
            throw MuseUsageError.parseFailed("Muse Keychain payload is not valid JSON")
        }
        return try self.requireAccessToken(payload.accessToken)
    }

    static func authFileURL(
        environment: [String: String],
        homeDirectory: URL) -> URL
    {
        if let override = environment[self.authPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private static func authFileRecord(
        environment: [String: String],
        homeDirectory: URL) -> AuthFileRecord?
    {
        let url = self.authFileURL(environment: environment, homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let meta = file.providers?.meta
        else {
            return nil
        }
        let token = try? self.requireAccessToken(meta.accessToken)
        let isOAuth = meta.mechanism?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth"
        guard token != nil || isOAuth else { return nil }
        return AuthFileRecord(accessToken: token)
    }

    private static func keychainAccessToken() throws -> String? {
        #if os(macOS)
        guard !KeychainAccessGate.isDisabled else {
            throw MuseUsageError.keychainUnavailable
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw MuseUsageError.parseFailed("Muse Keychain item was empty")
            }
            return try self.accessToken(fromKeychainPayload: data)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem:
            throw MuseUsageError.keychainUnavailable
        default:
            throw MuseUsageError.keychainUnavailable
        }
        #else
        return nil
        #endif
    }

    private static func requireAccessToken(_ raw: String?) throws -> String {
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw MuseUsageError.invalidCredentials
        }
        guard token.hasPrefix(self.accessTokenPrefix) else {
            throw MuseUsageError.invalidCredentials
        }
        return token
    }

    private struct AuthFileRecord {
        let accessToken: String?
    }

    private struct AuthFile: Decodable {
        let providers: Providers?

        struct Providers: Decodable {
            let meta: Meta?
        }

        struct Meta: Decodable {
            let mechanism: String?
            let accessToken: String?

            enum CodingKeys: String, CodingKey {
                case mechanism
                case accessToken = "access_token"
            }
        }
    }

    private struct KeychainPayload: Decodable {
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}
