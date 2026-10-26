import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
struct CursorAppAuthEncryptionTests {
    static let password = "synthetic-cursor-safe-storage-password"

    @Test
    func `encrypted app token retains JWT identity expiry and session cookie`() throws {
        let token = try makeCursorAppAuthToken(subject: "auth0|encrypted-account")
        let session = try Self.withKeychain { try #require(try Self.load(Self.envelope(token))) }
        #expect(session.accessToken == token)
        #expect(session.isUsable)
        #expect(session.identity?.requestUsageUserID == "encrypted-account")
        #expect(try session.cookieHeader() == "WorkosCursorSessionToken=encrypted-account%3A%3A" + token)
    }

    @Test
    func `plain tokens and malformed envelopes never request Safe Storage`() throws {
        let plain = try makeCursorAppAuthToken()
        for token in [
            plain,
            "cursor-safe-storage:v1:" + plain,
            "cursor-safe-storage:v2:" + plain,
            "cursor-safe-storage:v1:!",
            "cursor-safe-storage:v2:AAAA",
            "cursor-safe-storage:v1:" + Data("v10short".utf8).base64EncodedString(),
        ] {
            try Self.withKeychain(preflight: .interactionRequired) { _ in
                Issue.record("A plain token or malformed envelope must not request a secret")
                return (errSecSuccess, nil)
            } operation: {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    Issue.record("A plain token or malformed envelope must not access Keychain metadata")
                    return .notFound
                } operation: {
                    let session = try #require(try Self.load(token))
                    #expect(session.accessToken == (token == plain ? token : ""))
                    #expect(session.isUsable == (token == plain))
                }
            }
        }
    }

    @Test
    func `raw session cookies preserve cookie-like user IDs`() throws {
        let token = try makeCursorAppAuthToken(subject: "auth0|user-cookie")
        let header = "unrelated=value; WorkosCursorSessionToken=user-cookie::" + token
        #expect(CursorAppAuthSession.from(cookieHeader: header)?.accessToken == token)
        #expect(CursorSessionIdentity.from(cookieHeader: header)?.requestUsageUserID == "user-cookie")
    }

    @Test
    func `decryption preserves expiry and user ID rejection`() throws {
        for token in try [
            makeCursorAppAuthToken(expiration: Date(timeIntervalSinceNow: -120)),
            makeCursorAppAuthToken(subject: "auth0|invalid;user"),
        ] {
            let session = try Self.withKeychain { try #require(try Self.load(Self.envelope(token))) }
            #expect(session.accessToken == token)
            #expect(!session.isUsable)
        }
    }

    @Test
    func `wrong Safe Storage password fails closed`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let session = try Self.withKeychain { _ in (errSecSuccess, Data("wrong-synthetic-password".utf8)) } operation: {
            try #require(try Self.load(envelope))
        }
        #expect(session.accessToken.isEmpty)
        #expect(!session.isUsable)
    }

    @Test
    func `background denied no UI read falls through without reviving stale app auth`() async throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        let session = try Self.withKeychain { query in
            Self.expectNoUI(query)
            reads.setValue(reads.value + 1)
            return (errSecInteractionNotAllowed, nil)
        } operation: { try #require(try Self.load(envelope)) }
        #expect(reads.value == 1)
        #expect(session.accessToken.isEmpty)
        #expect(!session.isUsable)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CursorSessionStore(fileURL: directory.appendingPathComponent("session.json"))
        let stale = try CursorAppAuthSession(accessToken: makeCursorAppAuthToken(subject: "auth0|old-account"))
            .makeCookie()
        let browser = try #require(HTTPCookie(properties: [
            .name: "WorkosCursorSessionToken", .value: "synthetic-browser-session",
            .domain: "cursor.com", .path: "/", .secure: true,
        ]))
        await store.setCookies([stale, browser])
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            appAuthStore: CursorAppAuthSessionProviderStub(session: session),
            sessionStore: store,
            conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator())
        let header = try await KeychainCacheStore.withServiceOverrideForTesting("cursor-encryption-\(UUID())") {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CookieHeaderCache
                    .withLegacyBaseURLOverrideForTesting(directory.appendingPathComponent("legacy")) {
                        try await probe.resolveSession { cookieHeader, _ in cookieHeader }
                    }
            }
        }
        #expect(header == "WorkosCursorSessionToken=synthetic-browser-session")
        #expect(await store.getCookies().allSatisfy { !CursorAppAuthSession.isPersistedCookie($0) })
    }

    @Test
    func `background and settings cannot promote an untrusted Cursor key`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        for settings in [false, true] {
            try Self.withKeychain(
                preflight: .interactionRequired,
                interaction: settings ? .userInitiated : .background)
            { _ in
                Issue.record("No secret read is allowed")
                return (errSecSuccess, nil)
            } operation: {
                try BrowserCookieAccessGate.withExplicitRetry {
                    try BrowserCookieKeychainAccessGate.$isUserInteractionDisallowed.withValue(settings) {
                        let session = try #require(try Self.load(envelope))
                        #expect(!session.isUsable)
                    }
                }
            }
        }
    }

    @Test
    func `manual Cursor read shares one allowance with browser Safe Storage`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        try Self.withKeychain(preflight: .interactionRequired, interaction: .userInitiated) { query in
            #expect(query[kSecUseAuthenticationContext as String] == nil)
            #expect(query[kSecUseAuthenticationUI as String] == nil)
            reads.setValue(reads.value + 1)
            return (errSecSuccess, Data(Self.password.utf8))
        } operation: {
            try BrowserCookieAccessGate.withExplicitRetry {
                let first = try Self.load(envelope)
                let second = try Self.load(envelope)
                #expect(first?.isUsable == true)
                #expect(second?.isUsable == false)
                #expect(!BrowserCookieAccessGate.claimCredentialRead(service: "Chrome Safe Storage"))
            }
        }
        #expect(reads.value == 1)
    }

    @Test
    func `manual denial cooldown survives the next action`() throws {
        let envelope = try Self.envelope(makeCursorAppAuthToken())
        let reads = LockIsolated(0)
        try Self.withKeychain(preflight: .interactionRequired, interaction: .userInitiated) { _ in
            reads.setValue(reads.value + 1)
            return (errSecUserCanceled, nil)
        } operation: {
            for _ in 0..<2 {
                try BrowserCookieAccessGate.withExplicitRetry {
                    let session = try Self.load(envelope)
                    #expect(session?.isUsable == false)
                }
            }
        }
        #expect(reads.value == 1)
    }

    private static func expectNoUI(_ query: [String: Any]) {
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(query[kSecUseAuthenticationUI as String] as? String == KeychainNoUIQuery.uiFailPolicyForTesting())
    }

    static func withKeychain<T>(
        preflight: KeychainAccessPreflight.Outcome = .allowed,
        interaction: ProviderInteraction = .background,
        read: @escaping @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            Self.expectNoUI(query)
            return (errSecSuccess, Data(Self.password.utf8))
        },
        operation: () throws -> T) rethrows -> T
    {
        let lookup: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            #expect(query[kSecAttrService as String] as? String == "Cursor Safe Storage")
            #expect(query[kSecAttrAccount as String] as? String == "Cursor")
            #expect(query[kSecReturnData as String] as? Bool == true)
            return read(query)
        }
        let promptHandler = BrowserCookieKeychainPromptHandler.handler
        BrowserCookieKeychainPromptHandler.handler = nil
        defer { BrowserCookieKeychainPromptHandler.handler = promptHandler }
        return try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try BrowserCookieAccessGate.withIsolatedStateForTesting {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { service, account in
                    #expect(service == "Cursor Safe Storage")
                    #expect(account == "Cursor")
                    return preflight
                } operation: {
                    try ChromiumSafeStorage.$readOverrideForTesting.withValue(lookup) {
                        try ProviderInteractionContext.$current.withValue(interaction, operation: operation)
                    }
                }
            }
        }
    }

    static func envelope(_ token: String) throws -> String {
        try self.envelope(Data(token.utf8))
    }

    static func envelope(_ plaintext: Data) throws -> String {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            Self.password.withCString { password in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        Self.password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128)
                }
            }
        }
        try #require(derived == kCCSuccess)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var encrypted = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = encrypted.count
        var count = 0
        let result = encrypted.withUnsafeMutableBytes { output in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            input.baseAddress,
                            plaintext.count,
                            output.baseAddress,
                            capacity,
                            &count)
                    }
                }
            }
        }
        try #require(result == kCCSuccess)
        encrypted.count = count
        return "cursor-safe-storage:v1:" + (Data("v10".utf8) + encrypted).base64EncodedString()
    }

    static func load(_ token: String) throws -> CursorAppAuthSession? {
        try self.withDatabase(token) { try CursorAppAuthStore(dbPath: $0).loadSession() }
    }

    static func withDatabase<T>(_ token: String, operation: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) ==
            SQLITE_OK)
        var stmt: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db,
            "INSERT INTO ItemTable VALUES('cursorAuth/accessToken', ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        try #require(sqlite3_bind_text(stmt, 1, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) ==
            SQLITE_OK)
        try #require(sqlite3_step(stmt) == SQLITE_DONE)
        return try operation(path)
    }
}
