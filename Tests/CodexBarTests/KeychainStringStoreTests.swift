import Foundation
import Security
import Testing
@testable import CodexBarCore

struct KeychainStringStoreTests {
    @Test
    func `disabled access skips reads writes and preflight`() throws {
        let backend = Backend()
        let store = self.store(backend)
        try KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(try store.load() == nil)
            #expect(try store.store("synthetic-value") == false)
            try store.store(nil)
        }
        #expect(backend.calls.isEmpty)
    }

    @Test
    func `load retains item identity and trims stored strings`() throws {
        let backend = Backend(data: Data("  synthetic-value\n".utf8))
        let value = try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try self.store(backend).load()
        }
        #expect(value == "synthetic-value")
        #expect(backend.calls == ["preflight", "read"])
        #expect(backend.context?.service == "com.steipete.CodexBar")
        #expect(backend.context?.account == "synthetic-test-account")
        #expect(backend.query?[kSecAttrAccount as String] as? String == "synthetic-test-account")
        #expect(backend.query?[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(backend.query?[kSecReturnData as String] as? Bool == true)
    }

    @Test(arguments: [Data(), Data(" \n".utf8), Data([0xFF])])
    func `empty and non UTF8 stored strings remain absent`(data: Data) throws {
        let backend = Backend(data: data)
        try KeychainAccessGate.withTaskOverrideForTesting(false) {
            let value = try self.store(backend).load()
            #expect(value == nil)
        }
    }

    @Test
    func `missing items are absent and malformed results or failures throw`() throws {
        try KeychainAccessGate.withTaskOverrideForTesting(false) {
            let missing = try self.store(Backend(readStatus: errSecItemNotFound)).load()
            #expect(missing == nil)
            #expect(throws: KeychainStringStoreError.invalidData) {
                try self.store(Backend()).load()
            }
            #expect(throws: KeychainStringStoreError.keychainStatus(errSecAuthFailed)) {
                try self.store(Backend(readStatus: errSecAuthFailed)).load()
            }
        }
    }

    @Test(arguments: [errSecSuccess, errSecItemNotFound])
    func `writes update existing items and add only missing items`(updateStatus: OSStatus) throws {
        let backend = Backend(updateStatus: updateStatus)
        let stored = try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try self.store(backend).store("  synthetic-value\n")
        }
        #expect(stored)
        #expect(backend.calls == (updateStatus == errSecSuccess ? ["update"] : ["update", "add"]))
        #expect(backend.attributes?[kSecValueData as String] as? Data == Data("synthetic-value".utf8))
        #expect(backend.attributes?[kSecAttrAccessible as String] as? String ==
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(backend.query?[kSecAttrService as String] as? String == "com.steipete.CodexBar")
        #expect(backend.query?[kSecAttrAccount as String] as? String == "synthetic-test-account")
    }

    @Test(arguments: [nil, "", " \n", "invalid-cookie"] as [String?])
    func `empty or rejected writes delete the item`(value: String?) throws {
        let backend = Backend()
        let stored = try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try self.store(backend).store(value, isValid: { $0 != "invalid-cookie" })
        }
        #expect(stored)
        #expect(backend.calls == ["delete"])
    }

    @Test
    func `write failures propagate without falling back to a different operation`() throws {
        let updateFailure = Backend(updateStatus: errSecAuthFailed)
        let addFailure = Backend(updateStatus: errSecItemNotFound, mutationStatus: errSecAuthFailed)
        let deleteFailure = Backend(mutationStatus: errSecAuthFailed)
        try KeychainAccessGate.withTaskOverrideForTesting(false) {
            for backend in [updateFailure, addFailure] {
                #expect(throws: KeychainStringStoreError.keychainStatus(errSecAuthFailed)) {
                    try self.store(backend).store("synthetic-value")
                }
            }
            #expect(throws: KeychainStringStoreError.keychainStatus(errSecAuthFailed)) {
                try self.store(deleteFailure).store(nil)
            }
            try self.store(Backend(mutationStatus: errSecItemNotFound)).store(nil)
        }
        #expect(updateFailure.calls == ["update"])
        #expect(addFailure.calls == ["update", "add"])
        #expect(deleteFailure.calls == ["delete"])
    }

    private func store(_ backend: Backend) -> KeychainStringStore {
        KeychainStringStore(
            account: "synthetic-test-account",
            promptKind: .kimiToken,
            logCategory: "keychain-string-store-tests",
            operations: backend.operations)
    }

    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedCalls: [String] = []
        private var recordedQuery: [String: Any]?
        private var recordedAttributes: [String: Any]?
        private var recordedContext: KeychainPromptContext?
        private let data: Data?
        private let readStatus: OSStatus
        private let updateStatus: OSStatus
        private let mutationStatus: OSStatus

        init(
            data: Data? = nil,
            readStatus: OSStatus = errSecSuccess,
            updateStatus: OSStatus = errSecSuccess,
            mutationStatus: OSStatus = errSecSuccess)
        {
            self.data = data
            self.readStatus = readStatus
            self.updateStatus = updateStatus
            self.mutationStatus = mutationStatus
        }

        var calls: [String] {
            self.lock.withLock { self.recordedCalls }
        }

        var query: [String: Any]? {
            self.lock.withLock { self.recordedQuery }
        }

        var attributes: [String: Any]? {
            self.lock.withLock { self.recordedAttributes }
        }

        var context: KeychainPromptContext? {
            self.lock.withLock { self.recordedContext }
        }

        var operations: KeychainStringStore.Operations {
            .init(
                read: { query in
                    self.record("read", query: query)
                    return (self.readStatus, self.data)
                },
                update: { query, attributes in
                    self.record("update", query: query, attributes: attributes)
                    return self.updateStatus
                },
                add: { query in
                    self.record("add", query: query, attributes: query)
                    return self.mutationStatus
                },
                delete: { query in
                    self.record("delete", query: query)
                    return self.mutationStatus
                },
                preflight: { context in
                    self.lock.withLock {
                        self.recordedCalls.append("preflight")
                        self.recordedContext = context
                    }
                })
        }

        private func record(_ call: String, query: [String: Any], attributes: [String: Any]? = nil) {
            self.lock.withLock {
                self.recordedCalls.append(call)
                self.recordedQuery = query
                self.recordedAttributes = attributes
            }
        }
    }
}
