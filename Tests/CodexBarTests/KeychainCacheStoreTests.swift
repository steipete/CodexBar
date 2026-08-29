import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KeychainCacheStoreTests {
    struct TestEntry: Codable, Equatable {
        let value: String
        let storedAt: Date
    }

    @Test
    func `tests suppress real keychain access by default`() {
        guard ProcessInfo.processInfo.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }

        #expect(KeychainCacheStore.canUseRealKeychainForTesting == false)
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "implicit", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .interactionRequired, .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected implicit test cache entry")
        }
    }

    @Test
    func `implicit test store override stays isolated from explicit test store`() {
        let service = "implicit-test-store-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let explicitEntry = TestEntry(value: "explicit", storedAt: Date(timeIntervalSince1970: 1))
        let implicitEntry = TestEntry(value: "implicit", storedAt: Date(timeIntervalSince1970: 2))

        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.store(key: key, entry: explicitEntry)
            KeychainCacheStore.withImplicitTestStoreForTesting {
                #expect(self.loadedEntry(for: key) == nil)
                KeychainCacheStore.store(key: key, entry: implicitEntry)
                #expect(self.loadedEntry(for: key) == implicitEntry)
            }
            #expect(self.loadedEntry(for: key) == explicitEntry)
        }
    }

    @Test
    func `background interaction keeps real keychain cache available for no UI reads writes and deletes`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ProviderInteractionContext.$current.withValue(.background) {
                #expect(KeychainCacheStore.canUseRealKeychainForTesting == true)
                #expect(KeychainCacheStore.canEnumerateOrDeleteRealKeychainForTesting == true)
            }
        }
    }

    private func loadedEntry(for key: KeychainCacheStore.Key) -> TestEntry? {
        guard case let .found(entry) = KeychainCacheStore.load(key: key, as: TestEntry.self) else { return nil }
        return entry
    }

    @Test
    func `stores and loads entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let storedAt = Date(timeIntervalSince1970: 0)
        let entry = TestEntry(value: "alpha", storedAt: storedAt)

        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .interactionRequired, .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry")
        }
    }

    @Test
    func `overwrites existing entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let first = TestEntry(value: "first", storedAt: Date(timeIntervalSince1970: 1))
        let second = TestEntry(value: "second", storedAt: Date(timeIntervalSince1970: 2))

        KeychainCacheStore.store(key: key, entry: first)
        KeychainCacheStore.store(key: key, entry: second)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == second)
        case .interactionRequired, .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected overwritten keychain cache entry")
        }
    }

    @Test
    func `clear removes entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.store(key: key, entry: entry)
        KeychainCacheStore.clear(key: key)

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case .missing:
            #expect(true)
        case .found, .interactionRequired, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry to be cleared")
        }
    }

    @Test
    func `clear reports whether an entry was removed`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)

        #expect(KeychainCacheStore.clear(key: key) == true)
        #expect(KeychainCacheStore.clear(key: key) == false)
    }

    @Test
    func `keys lists only matching category for current service`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let serviceA = "cache-keys-a-\(UUID().uuidString)"
        let serviceB = "cache-keys-b-\(UUID().uuidString)"
        let cookieA = KeychainCacheStore.Key(category: "cookie", identifier: "codex")
        let scopedCookieA = KeychainCacheStore.Key(category: "cookie", identifier: "codex.managed.account")
        let oauthA = KeychainCacheStore.Key(category: "oauth", identifier: "codex")
        let cookieB = KeychainCacheStore.Key(category: "cookie", identifier: "claude")
        let entry = TestEntry(value: "value", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.withServiceOverrideForTesting(serviceA) {
            KeychainCacheStore.store(key: cookieA, entry: entry)
            KeychainCacheStore.store(key: scopedCookieA, entry: entry)
            KeychainCacheStore.store(key: oauthA, entry: entry)
        }
        KeychainCacheStore.withServiceOverrideForTesting(serviceB) {
            KeychainCacheStore.store(key: cookieB, entry: entry)
        }

        let keys = KeychainCacheStore.withServiceOverrideForTesting(serviceA) {
            KeychainCacheStore.keys(category: "cookie")
        }

        #expect(keys == [cookieA, scopedCookieA])
    }

    #if os(macOS)
    @Test
    func `unsafe cache ACL remains unavailable without interaction`() {
        let service = "cache-preflight-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let observed = LockIsolated<(String, String?)?>(nil)
        let preflightCount = LockIsolated(0)

        let results: [KeychainCacheStore.LoadResult<TestEntry>] = KeychainCacheStore.withServiceOverrideForTesting(
            service)
        {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { candidateService, account in
                        observed.setValue((candidateService, account))
                        preflightCount.setValue(preflightCount.value + 1)
                        return .interactionRequired
                    } operation: {
                        [
                            KeychainCacheStore.load(key: key, as: TestEntry.self),
                            KeychainCacheStore.load(key: key, as: TestEntry.self),
                        ]
                    }
                }
            }
        }

        #expect(observed.value?.0 == service)
        #expect(observed.value?.1 == key.account)
        #expect(preflightCount.value == 1)
        for result in results {
            switch result {
            case .interactionRequired:
                break
            case .found, .invalid, .missing, .temporarilyUnavailable:
                Issue.record("Expected an unsafe cache item to remain unavailable")
            }
        }
    }

    @Test
    func `temporarily unavailable preflight remains retryable`() {
        let service = "cache-preflight-retry-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let preflightCount = LockIsolated(0)

        let results: [KeychainCacheStore.LoadResult<TestEntry>] = KeychainCacheStore.withServiceOverrideForTesting(
            service)
        {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        preflightCount.setValue(preflightCount.value + 1)
                        return .temporarilyUnavailable
                    } operation: {
                        [
                            KeychainCacheStore.load(key: key, as: TestEntry.self),
                            KeychainCacheStore.load(key: key, as: TestEntry.self),
                        ]
                    }
                }
            }
        }

        #expect(preflightCount.value == 2)
        for result in results {
            switch result {
            case .temporarilyUnavailable:
                break
            case .found, .interactionRequired, .invalid, .missing:
                Issue.record("Expected temporary preflight failure to remain retryable")
            }
        }
    }

    @Test
    func `cache secret read stops when attributes preflight finds no item`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let preflight: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in .notFound }
        let result: KeychainCacheStore.LoadResult<TestEntry> = KeychainCacheStore.withRealKeychainPathForTesting {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(preflight, operation: {
                    KeychainCacheStore.load(key: key, as: TestEntry.self)
                })
            }
        }

        switch result {
        case .missing:
            break
        case .found, .interactionRequired, .temporarilyUnavailable, .invalid:
            Issue.record("Expected a missing preflight item to skip the secret-data query")
        }
    }

    @Test
    func `cache store and clear stop when decrypt ACL requires interaction`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "blocked", storedAt: Date(timeIntervalSince1970: 0))
        let recorder = KeychainCacheStore.OperationRecorder()
        let preflightCount = LockIsolated(0)
        let preflight: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
            preflightCount.setValue(preflightCount.value + 1)
            return .interactionRequired
        }

        KeychainCacheStore.withRealKeychainPathForTesting {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.withOperationRecorderForTesting(recorder) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(preflight) {
                        #expect(KeychainCacheStore.storeResult(key: key, entry: entry) == false)
                        #expect(KeychainCacheStore.clearResult(key: key) == .failed)
                    }
                }
            }
        }

        #expect(recorder.operations == [.store, .clear])
        #expect(preflightCount.value == 1)
    }

    @Test
    func `interaction not allowed is treated as temporarily unavailable`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let result: KeychainCacheStore.LoadResult<TestEntry> = KeychainCacheStore.loadResultForKeychainReadFailure(
            status: errSecInteractionNotAllowed,
            key: key)

        switch result {
        case .temporarilyUnavailable:
            #expect(true)
        case .found, .interactionRequired, .missing, .invalid:
            #expect(Bool(false), "Expected temporary keychain lock to be retry-later")
        }
    }

    @Test
    func `delete interaction not allowed is non fatal`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        #expect(KeychainCacheStore.clearResultForKeychainDeleteStatus(
            errSecInteractionNotAllowed,
            key: key) == .failed)
    }

    @Test
    func `load failure override bypasses test store without affecting store or clear`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "stored", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
            case .temporarilyUnavailable:
                #expect(true)
            case .found, .interactionRequired, .missing, .invalid:
                #expect(Bool(false), "Expected override to run before test store")
            }
        }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .interactionRequired, .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected override not to mutate test store")
        }
    }

    @Test
    func `disabled keychain access keeps an in process memory cache`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        defer {
            KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
            KeychainAccessGate.resetOverrideForTesting()
        }

        let service = "disabled-memory-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "cookie", identifier: "cursor")
        let entry = TestEntry(value: "WorkosCursorSessionToken=memory", storedAt: Date(timeIntervalSince1970: 3))

        KeychainAccessGate.withTaskOverrideForTesting(true) {
            KeychainCacheStore.withDisabledAccessMemoryStoreForTesting(true) {
                KeychainCacheStore.withServiceOverrideForTesting(service) {
                    #expect(KeychainCacheStore.storeResult(key: key, entry: entry))
                    switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
                    case let .found(loaded):
                        #expect(loaded == entry)
                    case .interactionRequired, .missing, .temporarilyUnavailable, .invalid:
                        #expect(Bool(false), "Expected in-process memory cache entry")
                    }
                    #expect(KeychainCacheStore.keys(category: "cookie").contains(key))
                    #expect(KeychainCacheStore.clearResult(key: key) == .removed)
                    switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
                    case .missing:
                        break
                    case .found, .interactionRequired, .temporarilyUnavailable, .invalid:
                        #expect(Bool(false), "Expected memory cache entry to be cleared")
                    }
                }
            }
        }
    }

    @Test
    func `bundled ad hoc builds keep cookie cache in process memory`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        defer { KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting() }

        let service = "adhoc-memory-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key.cookie(provider: .claude)
        let entry = TestEntry(value: "sessionKey=memory", storedAt: Date(timeIntervalSince1970: 4))

        KeychainCacheStore.withBundledAdHocProcessForTesting(true) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(KeychainCacheStore.storeResult(key: key, entry: entry))
                #expect(self.loadedEntry(for: key) == entry)
                #expect(KeychainCacheStore.keys(category: "cookie") == [key])
                #expect(KeychainCacheStore.clearResult(key: key) == .removed)
                #expect(self.loadedEntry(for: key) == nil)
            }
        }
    }

    @Test
    func `certificate signed builds keep cookie cache in persistent store`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            KeychainCacheStore.setTestStoreForTesting(false)
            KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        }

        let service = "signed-persistent-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key.cookie(provider: .claude)
        let entry = TestEntry(value: "sessionKey=persistent", storedAt: Date(timeIntervalSince1970: 5))

        KeychainCacheStore.withBundledAdHocProcessForTesting(false) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(KeychainCacheStore.storeResult(key: key, entry: entry))
                #expect(self.loadedEntry(for: key) == entry)
            }
        }

        KeychainCacheStore.withBundledAdHocProcessForTesting(true) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(self.loadedEntry(for: key) == nil)
            }
        }

        KeychainCacheStore.withBundledAdHocProcessForTesting(false) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(self.loadedEntry(for: key) == entry)
                #expect(KeychainCacheStore.clearResult(key: key) == .removed)
            }
        }
    }

    @Test
    func `code signing certificate detection recognizes signed system code`() {
        #expect(KeychainCacheStore.hasCodeSigningCertificate(at: URL(fileURLWithPath: "/usr/bin/security")))
        #expect(!KeychainCacheStore.hasCodeSigningCertificate(
            at: URL(fileURLWithPath: "/path/that/does/not/exist")))
    }

    @Test
    func `bundled ad hoc builds do not move OAuth credentials into memory`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        defer {
            KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
            KeychainAccessGate.resetOverrideForTesting()
        }

        let service = "adhoc-memory-oauth-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key.oauth(provider: .claude)
        let entry = TestEntry(value: "synthetic-oauth-credential", storedAt: Date(timeIntervalSince1970: 5))

        KeychainAccessGate.withTaskOverrideForTesting(true) {
            KeychainCacheStore.withBundledAdHocProcessForTesting(true) {
                KeychainCacheStore.withServiceOverrideForTesting(service) {
                    #expect(!KeychainCacheStore.storeResult(key: key, entry: entry))
                    #expect(self.loadedEntry(for: key) == nil)
                    #expect(KeychainCacheStore.keysResult(category: "oauth") == .failed)
                }
            }
        }
    }

    @Test
    func `disabled keychain access does not retain OAuth entries in memory`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        defer {
            KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
            KeychainAccessGate.resetOverrideForTesting()
        }

        let service = "disabled-memory-oauth-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key.oauth(provider: .claude)
        let entry = TestEntry(value: "synthetic-oauth-credential", storedAt: Date(timeIntervalSince1970: 4))

        KeychainAccessGate.withTaskOverrideForTesting(true) {
            KeychainCacheStore.withDisabledAccessMemoryStoreForTesting(true) {
                KeychainCacheStore.withServiceOverrideForTesting(service) {
                    #expect(!KeychainCacheStore.storeResult(key: key, entry: entry))
                    #expect(self.loadedEntry(for: key) == nil)
                    #expect(KeychainCacheStore.keysResult(category: "oauth") == .failed)
                }
            }
        }
    }

    @Test
    func `toggling Keychain access clears the disabled access memory cache`() {
        KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
        defer {
            KeychainCacheStore.resetDisabledAccessMemoryStoreForTesting()
            KeychainAccessGate.resetOverrideForTesting()
        }

        let service = "disabled-memory-toggle-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "cookie", identifier: "cursor")
        let entry = TestEntry(value: "WorkosCursorSessionToken=stale", storedAt: Date(timeIntervalSince1970: 4))

        KeychainAccessGate.isDisabled = true
        KeychainCacheStore.withDisabledAccessMemoryStoreForTesting(true) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(KeychainCacheStore.storeResult(key: key, entry: entry))
                #expect(self.loadedEntry(for: key) == entry)
            }
        }

        KeychainAccessGate.isDisabled = false

        KeychainCacheStore.withDisabledAccessMemoryStoreForTesting(true) {
            KeychainCacheStore.withServiceOverrideForTesting(service) {
                #expect(self.loadedEntry(for: key) == nil)
            }
        }
    }

    @Test
    func `cache ACL trusts bundled app and CLI helper`() {
        let root = URL(fileURLWithPath: "/Applications/CodexBar.app")
        let executable = root.appendingPathComponent("Contents/MacOS/CodexBar")
        let helper = root.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        let existing = Set([
            root.path,
            executable.path,
            helper.path,
        ])

        let paths = KeychainCacheStore.trustedApplicationPathsForCacheAccess(
            bundleURL: root,
            executableURL: executable,
            fileExists: { existing.contains($0) })

        #expect(paths == [
            root.path,
            helper.path,
            executable.path,
        ])
    }

    @Test
    func `cache preflight inspects only the invoking executable`() {
        let root = URL(fileURLWithPath: "/Applications/CodexBar.app")
        let executable = root.appendingPathComponent("Contents/MacOS/CodexBar")
        let helper = root.appendingPathComponent("Contents/Helpers/CodexBarCLI")

        let currentPaths = KeychainCacheStore.invokingApplicationPathsForCacheAccess(
            executableURL: executable,
            fileExists: { $0 == executable.path })

        #expect(currentPaths == [executable.path])
        #expect(!currentPaths.contains(helper.path))
    }

    @Test
    func `cache ACL refuses bare dev binaries without an app bundle`() {
        // Trusting an ephemeral `swift build` binary would freeze a broken ACL
        // onto the shared item; the packaged app would then prompt on every read.
        let bundleURL = URL(fileURLWithPath: "/Users/dev/project/.build/debug")
        let executable = URL(fileURLWithPath: "/Users/dev/project/.build/debug/CodexBarCLI")

        let paths = KeychainCacheStore.trustedApplicationPathsForCacheAccess(
            bundleURL: bundleURL,
            executableURL: executable,
            fileExists: { _ in true })

        #expect(paths.isEmpty)
    }

    @Test
    func `blocked keychain access exports suppression for child processes`() {
        // Under tests access is always blocked; the decision must export the
        // suppression variable so spawned CLI children inherit it (their process
        // names match no test pattern).
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess())

        let exported = getenv(KeychainTestSafety.suppressAccessEnvironmentKey)
        #expect(exported != nil)
        #expect(exported.map { String(cString: $0) } == "1")
    }
    #endif
}
