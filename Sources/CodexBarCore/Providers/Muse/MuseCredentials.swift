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
        self.authFileRecord(environment: environment, homeDirectory: homeDirectory) != nil || self.hasKeychainItem()
    }

    public static func accessToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String
    {
        let authFile = self.authFileRecord(environment: environment, homeDirectory: homeDirectory)
        if let token = authFile?.accessToken {
            return try self.requireAccessToken(token)
        }
        do {
            if let token = try self.keychainAccessToken() {
                return token
            }
        } catch MuseUsageError.keychainAccessDisabled where authFile == nil {
            // With no metadata and lookup disabled, there is no detectable login.
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
        return homeDirectory.appendingPathComponent(".config/muse/auth.json")
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
        let inlineToken = meta.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = inlineToken.isEmpty ? nil : inlineToken
        let isOAuth = meta.mechanism?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth"
        guard token != nil || isOAuth else { return nil }
        return AuthFileRecord(accessToken: token)
    }

    #if os(macOS) && DEBUG
    @TaskLocal static var keychainReadOverrideForTesting: (@Sendable ([String: Any]) -> (OSStatus, Data?))?
    #endif

    /// Detects the CLI's Keychain login without requesting its secret, so availability and diagnostics checks
    /// can never show a Keychain prompt. Whether the token is readable is decided when usage is fetched.
    private static func hasKeychainItem() -> Bool {
        #if os(macOS)
        guard !KeychainAccessGate.isDisabled else { return false }
        return switch KeychainAccessPreflight.checkGenericPassword(
            service: self.keychainService,
            account: self.keychainAccount)
        {
        case .allowed, .interactionRequired, .temporarilyUnavailable: true
        case .notFound, .failure: false
        }
        #else
        return false
        #endif
    }

    private static func keychainAccessToken() throws -> String? {
        #if os(macOS)
        guard !KeychainAccessGate.isDisabled else {
            throw MuseUsageError.keychainAccessDisabled
        }
        // Legacy CLI-owned ACLs can prompt despite no-UI query flags. Inspect the ACL before requesting the secret.
        switch KeychainAccessPreflight.checkGenericPassword(
            service: self.keychainService,
            account: self.keychainAccount)
        {
        case .notFound:
            return nil
        case .allowed:
            return try self.readKeychainToken(allowPrompt: false)
        case .interactionRequired:
            // Only an explicit user action in the app may earn the grant through the system prompt.
            // Background refreshes and processes without the explanation alert (the CLI) never prompt.
            guard KeychainPromptHandler.isInstalled,
                  BrowserCookieAccessGate.claimCredentialRead(service: self.keychainService),
                  KeychainPromptHandler.notifyIfHandled(
                      KeychainPromptContext(
                          kind: .museToken,
                          service: self.keychainService,
                          account: self.keychainAccount))
            else {
                throw MuseUsageError.keychainAccessNotGranted
            }
            return try self.readKeychainToken(allowPrompt: true)
        case .temporarilyUnavailable, .failure:
            throw MuseUsageError.keychainUnavailable
        }
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func readKeychainToken(allowPrompt: Bool) throws -> String? {
        let (status, data) = self.readKeychainItem(allowPrompt: allowPrompt)
        switch status {
        case errSecSuccess:
            guard let data else {
                throw MuseUsageError.parseFailed("Muse Keychain item was empty")
            }
            return try self.accessToken(fromKeychainPayload: data)
        case errSecItemNotFound:
            return nil
        default:
            if allowPrompt, [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem].contains(status) {
                BrowserCookieAccessGate.recordCredentialDenial(service: self.keychainService)
                throw MuseUsageError.keychainAccessNotGranted
            }
            throw MuseUsageError.keychainUnavailable
        }
    }
    #endif

    #if os(macOS)
    private static func readKeychainItem(allowPrompt: Bool) -> (OSStatus, Data?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }
        #if DEBUG
        if let override = self.keychainReadOverrideForTesting {
            return override(query)
        }
        #endif
        var result: AnyObject?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    #endif

    private static func requireAccessToken(_ raw: String?) throws -> String {
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
