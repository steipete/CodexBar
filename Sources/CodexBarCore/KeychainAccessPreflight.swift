import Foundation

#if os(macOS)
import Darwin
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
        _ = self.notifyIfHandled(context)
    }

    @discardableResult
    static func notifyIfHandled(_ context: KeychainPromptContext) -> Bool {
        if let taskHandlerStore {
            taskHandlerStore.handler(context)
            return true
        }
        guard let handler else { return false }
        handler(context)
        return true
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

    private struct GenericPasswordKey: Hashable {
        let service: String
        let account: String?
    }

    private final class GenericPasswordCheckMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [GenericPasswordKey: Outcome] = [:]

        func outcome(
            for key: GenericPasswordKey,
            check: () -> Outcome) -> Outcome
        {
            self.lock.lock()
            defer { self.lock.unlock() }
            if let outcome = self.outcomes[key] {
                return outcome
            }
            let outcome = check()
            self.outcomes[key] = outcome
            return outcome
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainPreflight)
    @TaskLocal private static var genericPasswordCheckMemo: GenericPasswordCheckMemo?

    #if DEBUG
    final class CheckGenericPasswordOverrideStore: @unchecked Sendable {
        let check: (String, String?) -> Outcome

        init(check: @escaping (String, String?) -> Outcome) {
            self.check = check
        }
    }

    @TaskLocal private static var taskCheckGenericPasswordOverrideStore: CheckGenericPasswordOverrideStore?

    static var hasCheckGenericPasswordOverrideForTesting: Bool {
        self.taskCheckGenericPasswordOverrideStore != nil
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
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskCheckGenericPasswordOverrideStore.withValue(
            override.map(CheckGenericPasswordOverrideStore.init(check:)))
        {
            try await operation()
        }
    }
    #endif

    /// Reuses identical no-UI generic-password preflights within one synchronous operation.
    /// The scope is deliberately short-lived because Keychain items and their ACLs can change.
    public static func withMemoizedGenericPasswordChecks<T>(
        _ operation: () throws -> T) rethrows -> T
    {
        try self.$genericPasswordCheckMemo.withValue(GenericPasswordCheckMemo()) {
            try operation()
        }
    }

    public static func checkGenericPassword(service: String, account: String?) -> Outcome {
        let key = GenericPasswordKey(service: service, account: account)
        if let memo = self.genericPasswordCheckMemo {
            return memo.outcome(for: key) {
                self.checkGenericPasswordUncached(service: service, account: account)
            }
        }
        return self.checkGenericPasswordUncached(service: service, account: account)
    }

    private static func checkGenericPasswordUncached(service: String, account: String?) -> Outcome {
        #if os(macOS)
        #if DEBUG
        if let override = self.taskCheckGenericPasswordOverrideStore {
            return override.check(service, account)
        }
        #endif
        guard !KeychainAccessGate.isDisabled else { return .notFound }
        let query = self.makeGenericPasswordPreflightQuery(service: service, account: account)

        var result: AnyObject?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let item = self.keychainItem(fromPreflightResult: result),
                  self.decryptACLAllowsCurrentProcess(item: item)
            else {
                self.log.info(
                    "Keychain preflight requires interaction for the current process",
                    metadata: ["service": service])
                return .interactionRequired
            }
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

    #if os(macOS)
    static func makeGenericPasswordPreflightQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Preflight should never trigger UI. Avoid requesting the secret payload (`kSecReturnData`) because
            // some macOS configurations have been observed to show the legacy keychain prompt even with UI-fail.
            // The item reference lets us inspect its decrypt ACL before deciding whether a data query is safe.
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    static func decryptACLAllowsCurrentProcess(
        trustedApplicationValidationResults: [Bool]?,
        promptSelector: SecKeychainPromptSelector) -> Bool
    {
        // Any non-zero selector can require authentication based on the caller's signature state.
        // A background preflight cannot prove that condition safe, so fail closed.
        guard promptSelector.rawValue == 0 else { return false }
        // A nil application list means the ACL does not restrict callers. For an explicit list, at least one
        // stored code-signing requirement must validate against the invoking executable. A path match alone is
        // insufficient: legacy ACLs can retain an old build's signature at the same path and still show UI.
        guard let trustedApplicationValidationResults else { return true }
        return trustedApplicationValidationResults.contains(true)
    }

    private static func keychainItem(fromPreflightResult result: AnyObject?) -> SecKeychainItem? {
        guard let attributes = result as? [String: Any],
              let value = attributes[kSecValueRef as String]
        else { return nil }
        return unsafeDowncast(value as AnyObject, to: SecKeychainItem.self)
    }

    private static func decryptACLAllowsCurrentProcess(item: SecKeychainItem) -> Bool {
        guard let copyItemAccess = self.securityFunction(
            named: "SecKeychainItemCopyAccess",
            as: SecKeychainItemCopyAccessFunction.self),
            let copyMatchingACLs = self.securityFunction(
                named: "SecAccessCopyMatchingACLList",
                as: SecAccessCopyMatchingACLListFunction.self),
            let copyACLContents = self.securityFunction(
                named: "SecACLCopyContents",
                as: SecACLCopyContentsFunction.self)
        else { return false }

        var access: SecAccess?
        guard copyItemAccess(item, &access) == errSecSuccess,
              let access,
              let rawACLs = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawACLs as? [SecACL],
              !acls.isEmpty
        else { return false }

        let currentPaths = KeychainCacheStore.invokingApplicationPathsForCacheAccess()
        guard !currentPaths.isEmpty else { return false }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyACLContents(acl, &applications, &description, &selector) == errSecSuccess else {
                continue
            }
            guard let applications else {
                if self.decryptACLAllowsCurrentProcess(
                    trustedApplicationValidationResults: nil,
                    promptSelector: selector)
                {
                    return true
                }
                continue
            }
            guard let trustedApplications = applications as? [SecTrustedApplication] else { continue }
            let validationResults = trustedApplications.flatMap { application in
                currentPaths.map { currentPath in
                    self.trustedApplication(application, validatesExecutableAt: currentPath)
                }
            }
            if self.decryptACLAllowsCurrentProcess(
                trustedApplicationValidationResults: validationResults,
                promptSelector: selector)
            {
                return true
            }
        }
        return false
    }

    static func trustedApplication(
        _ application: SecTrustedApplication,
        validatesExecutableAt path: String) -> Bool
    {
        guard let validate = self.securityFunction(
            named: "SecTrustedApplicationValidateWithPath",
            as: SecTrustedApplicationValidateWithPathFunction.self)
        else { return false }
        return path.withCString { validate(application, $0) == errSecSuccess }
    }

    private typealias SecKeychainItemCopyAccessFunction = @convention(c) (
        SecKeychainItem,
        UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFunction = @convention(c) (
        SecAccess,
        CFTypeRef) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFunction = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>,
        UnsafeMutablePointer<CFString?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFunction = @convention(c) (
        SecTrustedApplication,
        UnsafePointer<CChar>) -> OSStatus

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW)

    private static func securityFunction<T>(named name: String, as _: T.Type) -> T? {
        guard let securityFrameworkHandle,
              let symbol = dlsym(securityFrameworkHandle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
    #endif
}
