#if os(macOS)
import Foundation
import Security

package enum KeychainStringStoreError: LocalizedError, Equatable {
    case keychainStatus(OSStatus)
    case invalidData

    package var errorDescription: String? {
        switch self {
        case let .keychainStatus(status): "Keychain error: \(status)"
        case .invalidData: "Keychain returned invalid data."
        }
    }
}

/// Stores a trimmed string in an existing generic-password item. Provider adapters retain their
/// account names, validation, and caching; this host owns the Security operations and access policy.
package struct KeychainStringStore: Sendable {
    struct Operations: Sendable {
        var read: @Sendable ([String: Any]) -> (OSStatus, Data?)
        var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        var add: @Sendable ([String: Any]) -> OSStatus
        var delete: @Sendable ([String: Any]) -> OSStatus
        var preflight: @Sendable (KeychainPromptContext) -> Void

        static let live = Self(
            read: { query in
                var result: CFTypeRef?
                let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            update: { KeychainSecurity.update($0 as CFDictionary, $1 as CFDictionary) },
            add: { KeychainSecurity.add($0 as CFDictionary, nil) },
            delete: { KeychainSecurity.delete($0 as CFDictionary) },
            preflight: { context in
                if KeychainAccessPreflight.checkGenericPassword(
                    service: context.service,
                    account: context.account).requiresInteraction
                {
                    KeychainPromptHandler.handler?(context)
                }
            })
    }

    private let context: KeychainPromptContext
    private let log: CodexBarLogger
    private let operations: Operations

    package init(account: String, promptKind: KeychainPromptContext.Kind, logCategory: String) {
        self.init(account: account, promptKind: promptKind, logCategory: logCategory, operations: .live)
    }

    init(
        account: String,
        promptKind: KeychainPromptContext.Kind,
        logCategory: String,
        operations: Operations)
    {
        self.context = KeychainPromptContext(kind: promptKind, service: "com.steipete.CodexBar", account: account)
        self.log = CodexBarLog.logger(logCategory)
        self.operations = operations
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.context.service,
            kSecAttrAccount as String: self.context.account!,
        ]
    }

    package func load() throws -> String? {
        guard !KeychainAccessGate.isDisabled else { return nil }
        var query = self.query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        self.operations.preflight(self.context)
        let (status, data) = self.operations.read(query)
        if status == errSecItemNotFound { return nil }
        try self.check(status, operation: "read")
        guard let data else { throw KeychainStringStoreError.invalidData }
        return Self.cleaned(String(data: data, encoding: .utf8))
    }

    @discardableResult
    package func store(_ value: String?, isValid: (String) -> Bool = { _ in true }) throws -> Bool {
        guard !KeychainAccessGate.isDisabled else { return false }
        guard let value = Self.cleaned(value), isValid(value) else {
            try self.delete()
            return true
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = self.query
        let status = self.operations.update(query, attributes)
        if status == errSecItemNotFound {
            try self.check(self.operations.add(query.merging(attributes) { _, new in new }), operation: "add")
        } else {
            try self.check(status, operation: "update")
        }
        return true
    }

    private func delete() throws {
        guard !KeychainAccessGate.isDisabled else { return }
        let status = self.operations.delete(self.query)
        if status != errSecItemNotFound {
            try self.check(status, operation: "delete")
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            self.log.error("Keychain \(operation) failed: \(status)")
            throw KeychainStringStoreError.keychainStatus(status)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
#endif
