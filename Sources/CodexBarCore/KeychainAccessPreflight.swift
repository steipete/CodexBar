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
        case factoryCookie
        case zaiToken
        case copilotToken
        case minimaxCookie
        case augmentCookie
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

    public static func checkGenericPassword(service: String, account: String?) -> Outcome {
        #if os(macOS)
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
            return .allowed
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            return .failure(Int(status))
        }
        #else
        return .notFound
        #endif
    }
}
