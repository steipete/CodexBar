#if os(macOS)
import LocalAuthentication
import Security
#endif

public struct KeychainPromptContext: Sendable {
    public enum Kind: Sendable {
        case claudeOAuth
        case codexCookie
        case claudeCookie
        case cursorCookie
        case opencodeCookie
        case factoryCookie
        case zaiToken
        case syntheticToken
        case copilotToken
        case kimiToken
        case kimiK2Token
        case minimaxCookie
        case minimaxToken
        case augmentCookie
        case ampCookie
    }

    public let kind: Kind
    public let service: String
    public let account: String?

    public init(kind: Kind, service: String, account: String?) {
        self.kind = kind
        self.service = service
        self.account = account
    }
}

public enum KeychainPromptHandler {
    public nonisolated(unsafe) static var handler: ((KeychainPromptContext) -> Void)?
}

public enum KeychainAccessPreflight {
    public enum Outcome: Sendable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainPreflight)

    public static func checkGenericPassword(service: String, account: String?) -> Outcome {
        #if os(macOS)
        guard !KeychainAccessGate.isDisabled else { return .notFound }
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            self.log.debug("Keychain preflight allowed", metadata: ["service": service])
            return .allowed
        case errSecItemNotFound:
            self.log.debug("Keychain preflight not found", metadata: ["service": service])
            return .notFound
        case errSecInteractionNotAllowed:
            self.log.info("Keychain preflight requires interaction", metadata: ["service": service])
            return .interactionRequired
        default:
            self.log.warning("Keychain preflight failed", metadata: ["service": service, "status": "\(status)"])
            return .failure(Int(status))
        }
        #else
        return .notFound
        #endif
    }
}
