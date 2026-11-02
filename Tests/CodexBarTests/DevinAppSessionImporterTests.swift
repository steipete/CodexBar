#if os(macOS)
import CommonCrypto
import Foundation
import Security
import SQLite3
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
struct DevinAppSessionImporterTests {
    static let password = "synthetic-devin-safe-storage-password"

    @Test
    func `Devin app session decrypts and picks up the internal organization`() throws {
        let sessions = try Self.withKeychain {
            try Self.importer(
                payload: Self.sessionsPayload(tokens: ["devin-synthetic.token.signature"]),
                organizationKeys: ["devin.desktopShell.spacesMigration.org_example12345"])
                .importSessions()
        }

        #expect(sessions.count == 1)
        #expect(sessions.first?.accessToken == "devin-synthetic.token.signature")
        #expect(sessions.first?.internalOrganizationID == "org_example12345")
        #expect(sessions.first?.organization == "organizations/org_example12345")
        #expect(sessions.first?.sourceLabel == "Devin app")
    }

    @Test
    func `Devin app session merges with browser sessions`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-merge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeLocalStorageLog([
            (key: "auth1_session", value: #"{"token":"auth1_synthetic-browser"}"#),
        ], to: directory)
        let candidates = [ChromiumLocalStorageDiscovery.Candidate(label: "Chrome Default", url: directory)]
        let importer = try Self.importer(
            payload: Self.sessionsPayload(tokens: ["devin-synthetic.app-token.signature"]))

        let sessions = try Self.withKeychain {
            try DevinSessionImporter.importSessions(
                browserDetection: BrowserDetection(homeDirectory: directory.path, cacheTTL: 0),
                candidates: candidates,
                devinAppImporter: importer)
        }

        #expect(sessions.map(\.accessToken) == ["auth1_synthetic-browser", "devin-synthetic.app-token.signature"])
        #expect(sessions.map(\.sourceLabel) == ["Chrome Default", "Devin app"])
    }

    @Test
    func `Devin app sessions deduplicate with browser session by token`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-dedup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = "devin-synthetic.shared-token.signature"
        try Self.writeLocalStorageLog([
            (key: "any-key", value: #"{"access_token":"\#(shared)"}"#),
        ], to: directory)
        let candidates = [ChromiumLocalStorageDiscovery.Candidate(label: "Chrome Default", url: directory)]
        let importer = try Self.importer(payload: Self.sessionsPayload(tokens: [shared]))

        let sessions = try Self.withKeychain {
            try DevinSessionImporter.importSessions(
                browserDetection: BrowserDetection(homeDirectory: directory.path, cacheTTL: 0),
                candidates: candidates,
                devinAppImporter: importer)
        }

        #expect(sessions.count == 1)
        #expect(sessions.first?.sourceLabel == "Chrome Default")
    }

    @Test
    func `missing Devin app database yields no sessions`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let importer = DevinAppSessionImporter(home: home.path)

        try Self.withKeychain(
            read: { _ in
                Issue.record("No Safe Storage read is allowed without a session blob")
                return (errSecSuccess, nil)
            },
            preflight: .notFound,
            operation: {
                #expect(importer.importSessions().isEmpty)
            })
    }

    @Test
    func `background refresh never prompts for the Devin Safe Storage key`() throws {
        let importer = try Self.importer(payload: Self.sessionsPayload(tokens: ["devin-synthetic.token.sig"]))

        let sessions = try Self.withKeychain(
            read: { _ in
                Issue.record("A background refresh must not reach an interactive Safe Storage read")
                return (errSecSuccess, Data(Self.password.utf8))
            },
            preflight: .interactionRequired,
            interaction: .background,
            operation: {
                importer.importSessions()
            })

        #expect(sessions.isEmpty)
    }

    @Test
    func `denied Safe Storage read yields no sessions`() throws {
        let importer = try Self.importer(payload: Self.sessionsPayload(tokens: ["devin-synthetic.token.sig"]))

        let sessions = try Self.withKeychain(
            read: { _ in (errSecUserCanceled, nil) },
            preflight: .allowed,
            operation: {
                importer.importSessions()
            })

        #expect(sessions.isEmpty)
    }

    @Test(arguments: ["{}", "[]", #"[{"id":"1"}]"#, #"{"data":[1,2,3]}"#])
    func `payloads without access tokens yield no sessions`(_ payload: String) throws {
        let importer = try Self.importer(payload: payload)

        let sessions = try Self.withKeychain {
            importer.importSessions()
        }

        #expect(sessions.isEmpty)
    }

    @Test
    func `several organizations stay unpicked`() throws {
        let importer = try Self.importer(
            payload: Self.sessionsPayload(tokens: ["devin-synthetic.token.sig"]),
            organizationKeys: [
                "devin.desktopShell.spacesMigration.org_first12345",
                "devin.desktopShell.localSessionAnnotations.org_second6789",
            ])

        let sessions = try Self.withKeychain {
            importer.importSessions()
        }

        #expect(sessions.count == 1)
        #expect(sessions.first?.organization == nil)
        #expect(sessions.first?.internalOrganizationID == nil)
    }

    @Test
    func `multiple extension sessions deduplicate tokens`() throws {
        let importer = try Self.importer(
            payloads: [
                Self.sessionsPayload(tokens: ["devin-synthetic.one.signature", "devin-synthetic.two.signature"]),
                Self.sessionsPayload(tokens: ["devin-synthetic.two.signature"]),
            ])

        let sessions = try Self.withKeychain {
            importer.importSessions()
        }

        #expect(sessions.map(\.accessToken) == ["devin-synthetic.one.signature", "devin-synthetic.two.signature"])
    }

    @Test
    func `Devin app local storage provides the organization`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("devin-app-org-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let localStorage = home.appendingPathComponent(
            "Library/Application Support/Devin/Local Storage/leveldb")
        try Self.writeLocalStorageLog([
            (key: "last-internal-org-for-external-org-v1-example", value: #""org_example12345""#),
        ], to: localStorage)
        let importer = try Self.importer(
            payload: Self.sessionsPayload(tokens: ["devin-synthetic.token.sig"]),
            home: home.path)

        let sessions = try Self.withKeychain {
            importer.importSessions()
        }

        #expect(sessions.count == 1)
        #expect(sessions.first?.organization == "org/example")
        #expect(sessions.first?.internalOrganizationID == "org_example12345")
    }

    // MARK: - Fixtures

    static func sessionsPayload(tokens: [String]) throws -> String {
        let sessions: [[String: Any]] = tokens.enumerated().map { index, token in
            [
                "id": "session-\(index)",
                "accessToken": token,
                "account": ["id": "google-oauth2|acct", "label": "Ken"],
                "scopes": [String](),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: sessions)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func withKeychain<T>(
        read: @escaping @Sendable ([String: Any]) -> (OSStatus, Data?) = { _ in
            (errSecSuccess, Data(Self.password.utf8))
        },
        preflight: KeychainAccessPreflight.Outcome = .allowed,
        interaction: ProviderInteraction = .background,
        operation: () throws -> T) throws -> T
    {
        let lookup: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            #expect(query[kSecAttrService as String] as? String == "Devin Safe Storage")
            #expect(query[kSecAttrAccount as String] as? String == "Devin Key")
            #expect(query[kSecReturnData as String] as? Bool == true)
            return read(query)
        }
        let promptHandler = BrowserCookieKeychainPromptHandler.handler
        BrowserCookieKeychainPromptHandler.handler = nil
        defer { BrowserCookieKeychainPromptHandler.handler = promptHandler }
        return try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try BrowserCookieAccessGate.withIsolatedStateForTesting {
                try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    preflight
                } operation: {
                    try ChromiumSafeStorage.$readOverrideForTesting.withValue(lookup) {
                        try ProviderInteractionContext.$current.withValue(interaction, operation: operation)
                    }
                }
            }
        }
    }

    static func importer(
        payload: String,
        organizationKeys: [String] = [],
        home: String? = nil) throws -> DevinAppSessionImporter
    {
        try self.importer(payloads: [payload], organizationKeys: organizationKeys, home: home)
    }

    static func importer(
        payloads: [String],
        organizationKeys: [String] = [],
        home: String? = nil) throws -> DevinAppSessionImporter
    {
        let home = home ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-app-\(UUID())").path
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-app-db-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        try #require(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(
            db,
            "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil) == SQLITE_OK)
        for (index, payload) in payloads.enumerated() {
            let secretValue = try #"{"type":"Buffer","data":[\#(Self.encrypted(payload))]}"#
            let key = #"secret://{"extensionId":"codeium.windsurf-\#(index)","key":"windsurf_auth.sessions"}"#
            try Self.insert(db: db, key: key, value: secretValue)
        }
        for key in organizationKeys {
            try Self.insert(db: db, key: key, value: "true")
        }
        return DevinAppSessionImporter(dbPath: dbPath, home: home)
    }

    private static func insert(db: OpaquePointer?, key: String, value: String) throws {
        var stmt: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES(?, ?)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        try #require(sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) ==
            SQLITE_OK)
        try #require(sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) ==
            SQLITE_OK)
        try #require(sqlite3_step(stmt) == SQLITE_DONE)
    }

    /// Encrypts like VS Code secret storage / Chromium v10: PBKDF2-HMAC-SHA1 saltysalt/1003 + AES-128-CBC,
    /// then returns the bytes as the comma-separated list inside `{"type":"Buffer","data":[…]}`.
    static func encrypted(_ plaintext: String) throws -> String {
        let plaintext = Data(plaintext.utf8)
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
        return (Data("v10".utf8) + encrypted).map(String.init).joined(separator: ",")
    }

    static func writeLocalStorageLog(_ entries: [(key: String, value: String)], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var batch = Data(repeating: 0, count: 8)
        batch.append(contentsOf: self.littleEndianBytes(UInt32(entries.count)))
        for entry in entries {
            let key = Data("_https://app.devin.ai\u{0000}\u{0001}\(entry.key)".utf8)
            batch.append(1)
            batch.append(self.varint32(key.count))
            batch.append(key)
            let encoded = Data([1]) + Data(entry.value.utf8)
            batch.append(self.varint32(encoded.count))
            batch.append(encoded)
        }
        var record = Data(repeating: 0, count: 4)
        record.append(contentsOf: self.littleEndianBytes(UInt16(batch.count)))
        record.append(1)
        record.append(batch)
        try record.write(to: directory.appendingPathComponent("000003.log"))
    }

    private static func varint32(_ value: Int) -> Data {
        var result = Data()
        var remaining = UInt32(value)
        while remaining >= 0x80 {
            result.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        result.append(UInt8(remaining))
        return result
    }

    private static func littleEndianBytes(_ value: some FixedWidthInteger) -> [UInt8] {
        let littleEndian = value.littleEndian
        return withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
#endif
