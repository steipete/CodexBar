import Crypto
import Foundation
import Testing
@testable import CodexBarCore

#if canImport(CommonCrypto)
@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexAccountTransferTests {
    private static let password = "correct horse battery"

    @Test
    func `password derivation matches an independent PBKDF2 SHA256 reference`() throws {
        let plaintext = Data("portable-account-test".utf8)
        let salt = Data(0..<16)
        let package = try CodexAccountTransferService.seal(
            plaintext: plaintext, password: Self.password, salt: salt)
        let envelope = try #require(JSONSerialization.jsonObject(with: package) as? [String: Any])
        let encodedSealed = try #require(envelope["sealed"] as? String)
        let combined = try #require(Data(base64Encoded: encodedSealed))
        // Python hashlib.pbkdf2_hmac("sha256", password, bytes(range(16)), 600000, 32).
        let referenceKey: [UInt8] = [
            0xBB, 0x06, 0xC8, 0xC0, 0xB1, 0xDD, 0x5B, 0xFD,
            0x4E, 0x40, 0xF4, 0xE2, 0x97, 0xA2, 0xD0, 0xE6,
            0x4D, 0xA7, 0xEF, 0x94, 0xB4, 0xB8, 0xEC, 0x20,
            0x98, 0x90, 0x21, 0xC8, 0xB4, 0x15, 0x36, 0xAD,
        ]
        var header = Data("CodexBar.CodexAccountTransfer".utf8)
        header.append(contentsOf: [0, 0, 0, 0, 1, 0, 9, 0x27, 0xC0])
        header.append(salt)
        let opened = try AES.GCM.open(
            AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: referenceKey), authenticating: header)
        #expect(opened == plaintext)
    }

    @Test
    func `export then import round trips multiple accounts with labels into new private homes`() throws {
        let source = try ImportFixture()
        let first = try source.seedTransferAccount(email: "one@example.com", accountID: "ws-one", label: "Team One")
        let second = try source.seedTransferAccount(email: "two@example.com", accountID: "ws-two")
        let live = try source.writeLive(email: "live@example.com", accountID: "live-ws")
        let package = try CodexAccountTransferService(store: source.store, homeFactory: source.homeFactory)
            .exportAccounts(password: Self.password)

        let text = try #require(String(data: package, encoding: .utf8))
        for forbidden in ["one@example.com", "access-", "ws-one", first.id.uuidString, source.root.path] {
            #expect(!text.contains(forbidden))
        }

        let destination = try ImportFixture()
        let report = try CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
            .importAccounts(data: package, password: Self.password)
        #expect(report == CodexAccountTransferReport(importedCount: 2, existingCount: 0, failures: []))

        let accounts = try destination.store.loadAccounts().accounts
        #expect(Set(accounts.map(\.email)) == ["one@example.com", "two@example.com"])
        #expect(accounts.first { $0.email == "one@example.com" }?.workspaceLabel == "Team One")
        #expect(accounts.first { $0.email == "two@example.com" }?.workspaceLabel == nil)
        #expect(!accounts.map(\.id).contains(first.id) && !accounts.map(\.id).contains(second.id))
        for account in accounts {
            let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
            #expect(home.deletingLastPathComponent().standardizedFileURL.path
                == destination.managedHomes.standardizedFileURL.path)
            #expect(try Self.mode(home) == 0o700)
            #expect(try Self.mode(home.appendingPathComponent("auth.json")) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == ["auth.json"])
        }
        // Source registry, source auth files and the destination's live auth are untouched.
        #expect(try source.store.loadAccounts().accounts.count == 2)
        #expect(try Data(contentsOf: source.liveAuth) == live)
        #expect(try Data(contentsOf: CodexAuthFingerprint.authFileURL(homePath: first.managedHomePath))
            == ImportFixture.authJSON(email: "one@example.com", accountID: "ws-one"))
        #expect(!FileManager.default.fileExists(atPath: destination.liveAuth.path))
    }

    @Test
    func `importing the same package twice is idempotent`() throws {
        let source = try ImportFixture()
        try source.seedTransferAccount(email: "one@example.com", accountID: "ws-one")
        let package = try CodexAccountTransferService(store: source.store, homeFactory: source.homeFactory)
            .exportAccounts(password: Self.password)
        let destination = try ImportFixture()
        let service = CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
        _ = try service.importAccounts(data: package, password: Self.password)
        let again = try service.importAccounts(data: package, password: Self.password)
        #expect(again == CodexAccountTransferReport(importedCount: 0, existingCount: 1, failures: []))
        #expect(try destination.store.loadAccounts().accounts.count == 1)
        #expect(destination.homeURLs().count == 1)
    }

    @Test
    func `conflicting credentials are reported per entry while others import`() throws {
        let source = try ImportFixture()
        try source.seedTransferAccount(email: "one@example.com", accountID: "ws-one")
        try source.seedTransferAccount(email: "two@example.com", accountID: "ws-two")
        let package = try CodexAccountTransferService(store: source.store, homeFactory: source.homeFactory)
            .exportAccounts(password: Self.password)

        let destination = try ImportFixture()
        let conflicting = try destination.seedTransferAccount(
            email: "one@example.com", accountID: "ws-one", suffix: "refreshed")
        let before = try Data(contentsOf: CodexAuthFingerprint.authFileURL(homePath: conflicting.managedHomePath))
        let report = try CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
            .importAccounts(data: package, password: Self.password)

        #expect(report.importedCount == 1)
        #expect(report.existingCount == 0)
        #expect(report.failures.map(\.email) == ["one@example.com"])
        #expect(try Data(contentsOf: CodexAuthFingerprint.authFileURL(homePath: conflicting.managedHomePath)) == before)
        #expect(try destination.store.loadAccounts().accounts.count == 2)
        #expect(destination.homeURLs().count == 2)
    }

    @Test
    func `wrong password and tampering fail generically before any registry write`() throws {
        let source = try ImportFixture()
        try source.seedTransferAccount()
        let package = try CodexAccountTransferService(store: source.store, homeFactory: source.homeFactory)
            .exportAccounts(password: Self.password)
        let destination = try ImportFixture()
        let registryBefore = try Data(contentsOf: destination.storeURL)
        let recorder = RecordingManagedCodexAccountStore(base: destination.store)
        let service = CodexAccountTransferService(store: recorder, homeFactory: destination.homeFactory)

        #expect(throws: CodexAccountTransferError.decryptionFailed) {
            try service.importAccounts(data: package, password: "another long password")
        }
        var envelope = try #require(JSONSerialization.jsonObject(with: package) as? [String: Any])
        let encodedSealed = try #require(envelope["sealed"] as? String)
        var sealed = try #require(Data(base64Encoded: encodedSealed))
        sealed[sealed.count / 2] ^= 0x01
        envelope["sealed"] = sealed.base64EncodedString()
        #expect(throws: CodexAccountTransferError.decryptionFailed) {
            try service.importAccounts(data: JSONSerialization.data(withJSONObject: envelope), password: Self.password)
        }
        let encodedSalt = try #require(envelope["salt"] as? String)
        var salt = try #require(Data(base64Encoded: encodedSalt))
        salt[0] ^= 0x01
        var saltTampered = try #require(JSONSerialization.jsonObject(with: package) as? [String: Any])
        saltTampered["salt"] = salt.base64EncodedString()
        #expect(throws: CodexAccountTransferError.decryptionFailed) {
            try service.importAccounts(
                data: JSONSerialization.data(withJSONObject: saltTampered), password: Self.password)
        }
        #expect(recorder.storedSnapshots.isEmpty)
        #expect(try Data(contentsOf: destination.storeURL) == registryBefore)
        #expect(destination.homeURLs().isEmpty)
    }

    @Test(arguments: ["version", "iterations", "saltLength", "badBase64Salt", "notJSON", "oversize", "oversizeSealed"])
    func `malformed or unsupported headers are rejected before key derivation`(kind: String) throws {
        let source = try ImportFixture()
        try source.seedTransferAccount()
        let package = try CodexAccountTransferService(store: source.store, homeFactory: source.homeFactory)
            .exportAccounts(password: Self.password)
        var envelope = try #require(JSONSerialization.jsonObject(with: package) as? [String: Any])
        let data: Data
        let expected: CodexAccountTransferError
        switch kind {
        case "version":
            envelope["version"] = 2
            data = try JSONSerialization.data(withJSONObject: envelope)
            expected = .unsupportedVersion
        case "iterations":
            envelope["iterations"] = 1000
            data = try JSONSerialization.data(withJSONObject: envelope)
            expected = .unsupportedIterations
        case "saltLength":
            envelope["salt"] = Data(repeating: 1, count: 8).base64EncodedString()
            data = try JSONSerialization.data(withJSONObject: envelope)
            expected = .invalidSalt
        case "badBase64Salt":
            envelope["salt"] = "!!!!!!!!!!!!!!!!!!!!!!"
            data = try JSONSerialization.data(withJSONObject: envelope)
            expected = .invalidSalt
        case "notJSON":
            data = Data("not json".utf8)
            expected = .invalidPackage
        case "oversize":
            data = Data(repeating: 0x20, count: CodexAccountTransferService.maximumPackageBytes + 1)
            expected = .packageTooLarge
        default:
            envelope["sealed"] = String(repeating: "A", count: CodexAccountTransferService.maximumPackageBytes * 2)
            data = try JSONSerialization.data(withJSONObject: envelope)
            expected = .packageTooLarge
        }
        let destination = try ImportFixture()
        #expect(throws: expected) {
            try CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
                .importAccounts(data: data, password: Self.password)
        }
        #expect(try destination.store.loadAccounts().accounts.isEmpty)
    }

    @Test
    func `export requires a long password and at least one readable portable account`() throws {
        let empty = try ImportFixture()
        let emptyService = CodexAccountTransferService(store: empty.store, homeFactory: empty.homeFactory)
        #expect(throws: CodexAccountTransferError.passwordTooShort) {
            try emptyService.exportAccounts(password: "short")
        }
        #expect(throws: CodexAccountTransferError.noAccounts) {
            try emptyService.exportAccounts(password: Self.password)
        }

        let fixture = try ImportFixture()
        let good = try fixture.seedTransferAccount(email: "good@example.com", accountID: "ws-good")
        let broken = try fixture.seedTransferAccount(email: "broken@example.com", accountID: "ws-broken")
        try FileManager.default.removeItem(
            atPath: CodexAuthFingerprint.authFileURL(homePath: broken.managedHomePath).path)
        let service = CodexAccountTransferService(store: fixture.store, homeFactory: fixture.homeFactory)
        #expect(throws: CodexAccountTransferError.accountUnreadable(email: "broken@example.com")) {
            try service.exportAccounts(password: Self.password)
        }
        let goodAuth = CodexAuthFingerprint.authFileURL(homePath: good.managedHomePath)
        #expect(FileManager.default.fileExists(atPath: goodAuth.path))
    }

    @Test
    func `export refuses metadata that differs from its credentials`() throws {
        let fixture = try ImportFixture()
        let home = fixture.managedHomes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = ImportFixture.authJSON(email: "meta@example.com", accountID: "ws-auth")
        try fixture.write(data, to: home)
        // Selected workspace differs from the auth default: importing would silently substitute it.
        try fixture.store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [ManagedCodexAccount(
            id: UUID(),
            email: "meta@example.com",
            providerAccountID: "ws-auth",
            workspaceAccountID: "ws-selected",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: data),
            managedHomePath: home.path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)]))
        #expect(throws: CodexAccountTransferError.accountNotPortable(email: "meta@example.com")) {
            try CodexAccountTransferService(store: fixture.store, homeFactory: fixture.homeFactory)
                .exportAccounts(password: Self.password)
        }
    }

    @Test
    func `package with inconsistent entries is rejected before any account is imported`() throws {
        let valid = ImportFixture.authJSON(email: "ok@example.com", accountID: "ws-ok")
        let other = ImportFixture.authJSON(email: "other@example.com", accountID: "ws-other")
        let payload = try CodexAccountTransferService.Payload(accounts: [
            .init(
                email: "ok@example.com",
                workspaceAccountID: "ws-ok",
                workspaceLabel: nil,
                authJSON: #require(String(data: valid, encoding: .utf8))),
            .init(
                email: "ok2@example.com",
                workspaceAccountID: "ws-other",
                workspaceLabel: nil,
                authJSON: #require(String(data: other, encoding: .utf8))),
        ])
        let package = try CodexAccountTransferService.seal(
            plaintext: CodexAccountTransferService.encodePayload(payload), password: Self.password)
        let destination = try ImportFixture()
        #expect(throws: CodexAccountTransferError.invalidPackage) {
            try CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
                .importAccounts(data: package, password: Self.password)
        }
        #expect(try destination.store.loadAccounts().accounts.isEmpty)
        #expect(destination.homeURLs().isEmpty)
    }

    @Test(arguments: ["tooMany", "oversizeAuth"])
    func `entry count and per-auth size caps are enforced`(kind: String) throws {
        let auth = try #require(String(
            data: ImportFixture.authJSON(email: "ok@example.com", accountID: "ws-ok"),
            encoding: .utf8))
        let entries: [CodexAccountTransferService.Entry] = kind == "tooMany"
            ? (0...CodexAccountTransferService.maximumAccounts).map { _ in
                .init(email: "ok@example.com", workspaceAccountID: "ws-ok", workspaceLabel: nil, authJSON: auth)
            }
            : [.init(
                email: "ok@example.com",
                workspaceAccountID: "ws-ok",
                workspaceLabel: nil,
                authJSON: String(repeating: " ", count: CodexImportSourceAuthReader.maximumBytes + 1))]
        let package = try CodexAccountTransferService.seal(
            plaintext: CodexAccountTransferService.encodePayload(.init(accounts: entries)), password: Self.password)
        let destination = try ImportFixture()
        #expect(throws: kind == "tooMany" ? CodexAccountTransferError.tooManyAccounts : .packageTooLarge) {
            try CodexAccountTransferService(store: destination.store, homeFactory: destination.homeFactory)
                .importAccounts(data: package, password: Self.password)
        }
        #expect(try destination.store.loadAccounts().accounts.isEmpty)
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }
}
#endif

#if canImport(CommonCrypto)
extension ImportFixture {
    /// Seeds a registered managed account with an optional workspace label and token suffix.
    @discardableResult
    func seedTransferAccount(
        email: String = "existing@example.com",
        accountID: String = "ws-existing",
        label: String? = nil,
        suffix: String = "token") throws -> ManagedCodexAccount
    {
        let id = UUID()
        let home = self.managedHomes.appendingPathComponent(id.uuidString, isDirectory: true)
        let data = Self.authJSON(email: email, accountID: accountID, suffix: suffix)
        try self.write(data, to: home)
        let account = ManagedCodexAccount(
            id: id,
            email: email,
            providerAccountID: accountID,
            workspaceLabel: label,
            workspaceAccountID: accountID,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: data),
            managedHomePath: home.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: self.store.loadAccounts().accounts + [account]))
        return account
    }
}
#endif
