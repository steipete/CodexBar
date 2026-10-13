import Foundation
import Security
import SQLite3
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import SweetCookieKit

@Suite(.serialized, CodexCredentialFixtures())
struct BrowserCookiePromptContractTests {
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var interactive = 0
        private let promptFreeServices: Set<String>
        private let deniesInteraction: Bool

        init(promptFreeBrowser: Browser? = nil, deniesInteraction: Bool = false) {
            self.deniesInteraction = deniesInteraction
            self.promptFreeServices = Set(promptFreeBrowser?.safeStorageLabels.map(\.service) ?? [])
        }

        var interactiveQueries: Int {
            self.lock.withLock { self.interactive }
        }

        func lookup(_ service: String, _ account: String, _ allowInteraction: Bool) -> (OSStatus, String?) {
            self.lock.withLock {
                if self.promptFreeServices.contains(service) {
                    return (errSecSuccess, "synthetic-safe-storage-password")
                }
                guard allowInteraction else { return (errSecInteractionNotAllowed, nil) }
                self.interactive += 1
                if self.deniesInteraction { return (errSecAuthFailed, nil) }
                return (errSecSuccess, "synthetic-safe-storage-password")
            }
        }
    }

    private func auditProvider(
        interaction: ProviderInteraction,
        preflight: KeychainAccessPreflight.Outcome) throws -> Int
    {
        let browsers: [Browser] = [.chrome, .edge, .brave]
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for browser in browsers {
            let relative = try #require(browser.chromiumProfileRelativePath)
            let directory = home.appendingPathComponent("Library/Application Support/\(relative)/Default/Network")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var db: OpaquePointer?
            #expect(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(
                db,
                "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('.xiaomimimo.com')",
                nil,
                nil,
                nil) == SQLITE_OK)
            sqlite3_close(db)
        }
        let detection = BrowserDetection(
            homeDirectory: home.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { path in
                browsers.contains { path == "/Applications/\($0.appBundleName).app" }
                    || FileManager.default.fileExists(atPath: path)
            },
            directoryContents: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        let keychain = FakeKeychain()
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in preflight } operation: {
                try BrowserCookieAccessGate.withExplicitRetry {
                    try ProviderInteractionContext.$current.withValue(interaction) {
                        _ = try Array(MiMoCookieImporter.importSessions(
                            browserDetection: detection,
                            loadRecords: { browser, _, _ in
                                guard browser.usesKeychainForCookieDecryption,
                                      BrowserCookieAccessGate.shouldAttempt(browser)
                                else { return [] }
                                // Replace the credential read, retaining the production gate and SweetCookieKit's
                                // actual label selection and interactive escalation. No real Keychain call occurs.
                                do {
                                    _ = try Self.readKey(for: browser, keychain: keychain)
                                    BrowserCookieAccessGate.recordAllowed(for: browser)
                                    let store = BrowserCookieStore(
                                        browser: browser,
                                        profile: .init(id: browser.rawValue, name: "Synthetic"),
                                        kind: .network,
                                        label: browser.displayName,
                                        databaseURL: nil)
                                    let records = ["api-platform_serviceToken", "userId"].map { name in
                                        BrowserCookieRecord(
                                            domain: "xiaomimimo.com",
                                            name: name,
                                            path: "/",
                                            value: "synthetic-session",
                                            expires: nil,
                                            isSecure: true,
                                            isHTTPOnly: true)
                                    }
                                    return [BrowserCookieStoreRecords(store: store, records: records)]
                                } catch {
                                    BrowserCookieAccessGate.recordIfNeeded(error)
                                }
                                return []
                            },
                            loadStores: { _ in [] }))
                    }
                }
            }
        }
        return keychain.interactiveQueries
    }

    private func withFakeKeychain<T>(_ operation: () throws -> T) rethrows -> T {
        BrowserCookieAccessGate.resetForTesting()
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let wasDisabled = BrowserCookieKeychainAccessGate.isDisabled
        let promptHandler = BrowserCookieKeychainPromptHandler.handler
        BrowserCookieKeychainAccessGate.isDisabled = false
        BrowserCookieKeychainPromptHandler.handler = nil
        defer {
            BrowserCookieKeychainAccessGate.isDisabled = wasDisabled
            BrowserCookieKeychainPromptHandler.handler = promptHandler
            BrowserCookieAccessGate.resetForTesting()
            ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        }
        return try KeychainAccessGate.withTaskOverrideForTesting(false, operation: operation)
    }

    private static func readKey(for browser: Browser, keychain: FakeKeychain) throws -> Data {
        try BrowserCookieAccessGate.withRecordReadInteractionPolicy {
            do {
                return try ChromeCookieImporter.chromeSafeStorageKey(for: browser, passwordLookup: keychain.lookup)
            } catch let error as ChromeCookieImporter.ImportError {
                throw BrowserCookieError.mapChromeError(error, browser: browser)
            }
        }
    }

    @Test
    func `prompt free reads preserve the allowance and nested imports share it`() throws {
        let keychain = FakeKeychain(promptFreeBrowser: .chrome)
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        #expect(keychain.interactiveQueries == 0)
                        try BrowserCookieAccessGate.withExplicitRetry {
                            _ = try Self.readKey(for: .brave, keychain: keychain)
                        }
                        #expect(keychain.interactiveQueries == 1)
                        #expect(throws: BrowserCookieError.self) { try Self.readKey(for: .arc, keychain: keychain) }
                        #expect(throws: BrowserCookieError.self) { try Self.readKey(for: .edge, keychain: keychain) }
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `a failed background read does not impose a denial cooldown`() throws {
        let keychain = FakeKeychain()
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                ProviderInteractionContext.$current.withValue(.background) {
                    do {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        Issue.record("Expected a no-UI read failure")
                    } catch {
                        BrowserCookieAccessGate.recordIfNeeded(error)
                    }
                }
                #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `an actual interactive denial blocks the next manual action`() {
        let keychain = FakeKeychain(deniesInteraction: true)
        self.withFakeKeychain {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                ProviderInteractionContext.$current.withValue(.userInitiated) {
                    BrowserCookieAccessGate.withExplicitRetry {
                        _ = try? Self.readKey(for: .chrome, keychain: keychain)
                    }
                    #expect(BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                    BrowserCookieAccessGate.withExplicitRetry {
                        #expect(!BrowserCookieAccessGate.shouldAttempt(.chrome))
                        #expect(!BrowserCookieAccessGate.shouldAttempt(.brave))
                        _ = try? Self.readKey(for: .chrome, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `spent allowance still permits cached reads with interaction required metadata`() throws {
        let keychain = FakeKeychain()
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                .interactionRequired
            } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        #expect(BrowserCookieAccessGate.shouldAttempt(.chrome))
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                    }
                }
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test
    func `acknowledged no UI recovery clears the browser denial`() throws {
        let keychain = FakeKeychain(promptFreeBrowser: .chrome)
        try self.withFakeKeychain {
            BrowserCookieAccessGate.recordDenied(for: .chrome)
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry(bypassingCooldown: true) {
                        _ = try Self.readKey(for: .chrome, keychain: keychain)
                        BrowserCookieAccessGate.recordAllowed(for: .chrome)
                    }
                    #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                    #expect(BrowserCookieAccessGate.shouldAttempt(.chrome))
                }
            }
        }
        #expect(keychain.interactiveQueries == 0)
    }

    @Test
    func `a sibling no UI failure cannot record an interactive denial`() throws {
        try self.withFakeKeychain {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try BrowserCookieAccessGate.withExplicitRetry {
                        try BrowserCookieAccessGate.withRecordReadInteractionPolicy {
                            if BrowserCookieKeychainAccessGate.isUserInteractionDisallowed {
                                throw BrowserCookieError.accessDenied(browser: .chrome, details: "Synthetic")
                            }
                            // Another read fails while this action's interactive read is still pending.
                            do {
                                try BrowserCookieAccessGate.withRecordReadInteractionPolicy { () throws in
                                    throw BrowserCookieError.accessDenied(browser: .chrome, details: "Synthetic")
                                }
                            } catch {
                                BrowserCookieAccessGate.recordIfNeeded(error)
                            }
                            #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                        }
                        BrowserCookieAccessGate.recordAllowed(for: .chrome)
                        #expect(!BrowserCookieAccessGate.hasActiveDenial(for: .chrome))
                    }
                }
            }
        }
    }

    @Test
    func `concurrent escaped imports share one atomic allowance`() {
        let keychain = FakeKeychain()
        self.withFakeKeychain {
            let read = ProviderInteractionContext.$current.withValue(.userInitiated) {
                BrowserCookieAccessGate.withExplicitRetry {
                    BrowserCookieAccessGate.operationPreservingAccessContext { (browser: Browser) in
                        try KeychainAccessGate.withTaskOverrideForTesting(false) {
                            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                                .allowed
                            } operation: {
                                try Self.readKey(for: browser, keychain: keychain)
                            }
                        }
                    }
                }
            }
            let browsers: [Browser] = [.chrome, .brave, .arc, .edge]
            DispatchQueue.concurrentPerform(iterations: browsers.count) { index in
                _ = try? read(browsers[index])
            }
        }
        #expect(keychain.interactiveQueries == 1)
    }

    @Test @MainActor
    func `settings observation refresh does not inherit interactive permission`() async throws {
        let fixture = CodexBackgroundRefreshCoalescingTests()
        let settings = try fixture.makeSettingsStore(suite: "BrowserCookiePromptContractTests-observation")
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        let store = fixture.makeStore(settings: settings)
        var observed: [ProviderInteraction] = []
        store._test_providerRefreshOverride = { _ in observed.append(ProviderInteractionContext.current) }
        defer { store._test_providerRefreshOverride = nil }
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refreshForSettingsChange()
        }
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { $0 == .background })
    }

    @Test @MainActor
    func `queued settings refresh cannot be promoted by a manual refresh`() {
        var automatic = UsageStore.RequiredRefreshRequest(
            throughGeneration: 1, coalesceProviderRefreshes: false, interaction: .background)
        var manual = UsageStore.RequiredRefreshRequest(
            throughGeneration: 2, coalesceProviderRefreshes: true, interaction: .userInitiated)
        automatic.merge(manual)
        manual.merge(automatic)
        #expect(automatic.interaction == .background)
        #expect(manual.interaction == .background)
    }

    @Test
    func `background automatic provider import never makes interactive queries`() throws {
        #expect(try self.auditProvider(interaction: .background, preflight: .interactionRequired) == 0)
        // Even a stale allowed preflight cannot promote the actual background decryption read to UI.
        #expect(try self.auditProvider(interaction: .background, preflight: .allowed) == 0)
    }

    @Test
    func `manual automatic provider import bounds unauthorized browsers to one prompt`() throws {
        #expect(try self.auditProvider(interaction: .userInitiated, preflight: .interactionRequired) == 1)
    }

    @Test
    func `manual automatic provider import bounds stale preflight grants to one prompt`() throws {
        #expect(try self.auditProvider(interaction: .userInitiated, preflight: .allowed) <= 1)
    }

    @Test
    func `manual retry respects a recent browser denial`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let now = Date()
        BrowserCookieAccessGate.recordDenied(for: .brave, now: now)
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight
                .withCheckGenericPasswordOverrideForTesting { _, _ in .interactionRequired } operation: {
                    BrowserCookieAccessGate.withExplicitRetry {
                        ProviderInteractionContext.$current.withValue(.userInitiated) {
                            #expect(!BrowserCookieAccessGate.shouldAttempt(.brave, now: now.addingTimeInterval(1)))
                        }
                    }
                }
        }
    }
}
