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
    final class HandlerStore: @unchecked Sendable {
        let handler: (KeychainPromptContext) -> Void

        init(handler: @escaping (KeychainPromptContext) -> Void) {
            self.handler = handler
        }
    }

    @TaskLocal private static var taskHandlerStore: HandlerStore?
    public nonisolated(unsafe) static var handler: ((KeychainPromptContext) -> Void)?

    public static func notify(_ context: KeychainPromptContext) {
        if let taskHandlerStore {
            taskHandlerStore.handler(context)
            return
        }
        self.handler?(context)
    }

    #if DEBUG
    static func withHandlerForTesting<T>(
        _ handler: ((KeychainPromptContext) -> Void)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskHandlerStore.withValue(handler.map(HandlerStore.init(handler:))) {
            try operation()
        }
    }

    static func withHandlerForTesting<T>(
        _ handler: ((KeychainPromptContext) -> Void)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskHandlerStore.withValue(handler.map(HandlerStore.init(handler:))) {
            try await operation()
        }
    }
    #endif
}

public enum KeychainAccessPreflight {
    public enum Outcome: Sendable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainPreflight)

    #if DEBUG
    final class CheckGenericPasswordOverrideStore: @unchecked Sendable {
        let check: (String, String?) -> Outcome

        init(check: @escaping (String, String?) -> Outcome) {
            self.check = check
        }
    }

    @TaskLocal private static var taskCheckGenericPasswordOverrideStore: CheckGenericPasswordOverrideStore?
    private nonisolated(unsafe) static var checkGenericPasswordOverride: ((String, String?) -> Outcome)?

    static func setCheckGenericPasswordOverrideForTesting(_ override: ((String, String?) -> Outcome)?) {
        self.checkGenericPasswordOverride = override
    }

    static func withCheckGenericPasswordOverrideForTesting<T>(
        _ override: ((String, String?) -> Outcome)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskCheckGenericPasswordOverrideStore.withValue(
            override.map(CheckGenericPasswordOverrideStore.init(check:)))
        {
            try operation()
        }
    }

    static func withCheckGenericPasswordOverrideForTesting<T>(
        _ override: ((String, String?) -> Outcome)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskCheckGenericPasswordOverrideStore.withValue(
            override.map(CheckGenericPasswordOverrideStore.init(check:)))
        {
            try await operation()
        }
    }
    #endif

    public static func checkGenericPassword(service: String, account: String?) -> Outcome {
        #if os(macOS)
        #if DEBUG
        if let override = self.taskCheckGenericPasswordOverrideStore {
            return override.check(service, account)
        }
        if let override = self.checkGenericPasswordOverride {
            return override(service, account)
        }
        #endif
        guard !KeychainAccessGate.isDisabled else { return .notFound }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Preflight should never trigger UI. Avoid requesting the secret payload (`kSecReturnData`) because
            // some macOS configurations have been observed to show the legacy keychain prompt even when
            // `kSecUseAuthenticationUIFail` is set.
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
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
            self.log.debug(
                "Keychain preflight not found",
                metadata: ["service": service])
            return .notFound
        case errSecInteractionNotAllowed:
            self.log.info(
                "Keychain preflight requires interaction",
                metadata: ["service": service])
            return .interactionRequired
        default:
            self.log.warning(
                "Keychain preflight failed",
                metadata: ["service": service, "status": "\(status)"])
            return .failure(Int(status))
        }
        #else
        return .notFound
        #endif
    }
}
