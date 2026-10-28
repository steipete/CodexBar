import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexManagedAccountImportTests {
    @Test
    func `valid profile imports privately and becomes promotion eligible without touching source or live auth`()
        async throws
    {
        let fixture = try ImportFixture()
        let source = try fixture.writeSource(email: "Import@Example.com", accountID: "Workspace-A")
        let live = try fixture.writeLive(email: "live@example.com", accountID: "live-ws")
        let receipt = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)

        #expect(receipt.outcome == .imported)
        #expect(receipt.email == "import@example.com")
        let account = try #require(fixture.store.loadAccounts().account(id: receipt.id))
        #expect(account.effectiveWorkspaceAccountID == "workspace-a")
        #expect(account.authFingerprint == CodexAuthFingerprint.fingerprint(data: source))
        #expect(fixture.homeURLs().map(\.lastPathComponent) == [receipt.id.uuidString])
        let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        #expect(try Self.mode(home) == 0o700)
        #expect(try Self.mode(home.appendingPathComponent("auth.json")) == 0o600)
        #expect(try Data(contentsOf: home.appendingPathComponent("auth.json")) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == ["auth.json"])
        #expect(try Data(contentsOf: fixture.sourceAuth) == source)
        #expect(try Data(contentsOf: fixture.liveAuth) == live)

        let swapper = RecordingCodexLiveAuthSwapper()
        let promotion = CodexAccountPromotionTransaction(
            store: fixture.store,
            homeFactory: fixture.homeFactory,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: swapper,
            baseEnvironment: ["CODEX_HOME": fixture.liveHome.path])
        let result = try await promotion.promoteManagedAccount(id: receipt.id)
        #expect(result.targetManagedAccountID == receipt.id)
        #expect(try Data(contentsOf: fixture.liveAuth) == source)
    }

    @Test
    func `receipt and error text carry no credential material`() throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "safe@example.com", accountID: "ws")
        let receipt = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        let json = try String(
            bytes: JSONEncoder().encode(CodexAccountImportReceipt(
                id: receipt.id.uuidString, email: receipt.email, outcome: receipt.outcome.rawValue)),
            encoding: .utf8) ?? ""
        for forbidden in ["access", "refresh", "fingerprint", "managedHomePath", "tokens"] {
            #expect(!json.contains(forbidden))
        }
        #expect(!(CodexManagedAccountImportError.accountExists.errorDescription ?? "").contains("access-"))
    }

    @Test(arguments: ImportFixture.RejectedProfile.allCases)
    func `unsupported or malformed profiles are rejected without changes`(
        profile: ImportFixture.RejectedProfile) throws
    {
        let fixture = try ImportFixture()
        let existing = try fixture.seedExistingAccount()
        let registryBefore = try Data(contentsOf: fixture.storeURL)
        let live = try fixture.writeLive(email: "live@example.com", accountID: "live-ws")
        try fixture.writeRejected(profile)
        #expect(throws: profile.expectedError) {
            try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        }
        #expect(try Data(contentsOf: fixture.storeURL) == registryBefore)
        #expect(fixture.homeURLs().map(\.lastPathComponent) == [existing.id.uuidString])
        #expect(try Data(contentsOf: fixture.liveAuth) == live)
    }

    @Test(arguments: ["relative/home", "", "~/profile", "/tmp/../etc", "/a/b/.."])
    func `raw relative or traversing source paths are rejected before reading`(raw: String) throws {
        let fixture = try ImportFixture()
        let reader = CountingReader()
        #expect(throws: CodexManagedAccountImportError.sourcePathNotAbsolute) {
            try CodexBarCLI.importCodexProfile(
                fromRawHome: raw, store: fixture.store, homeFactory: fixture.homeFactory, reader: reader)
        }
        #expect(reader.reads == 0)
        #expect(throws: CodexManagedAccountImportError.sourcePathNotAbsolute) {
            try fixture.transaction(reader: reader).importProfile(
                fromHome: URL(fileURLWithPath: fixture.sourceHome.path + "/../x"))
        }
        #expect(reader.reads == 0)
        #expect(try fixture.store.loadAccounts().accounts.isEmpty)
    }

    @Test
    func `CLI import helper accepts an absolute path and returns a safe receipt`() throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "cli@example.com", accountID: "ws")
        let receipt = try CodexBarCLI.importCodexProfile(
            fromRawHome: fixture.sourceHome.path, store: fixture.store, homeFactory: fixture.homeFactory)
        #expect(receipt.outcome == "imported")
        #expect(receipt.email == "cli@example.com")
    }

    @Test
    func `symlinked source auth is rejected and its target is untouched`() throws {
        let fixture = try ImportFixture()
        let real = fixture.root.appendingPathComponent("real-auth.json")
        let data = ImportFixture.authJSON(email: "link@example.com", accountID: "ws")
        try data.write(to: real)
        try FileManager.default.createDirectory(at: fixture.sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.sourceAuth, withDestinationURL: real)
        // Fixture isolation denies symlinked credential paths (reported as missing); production rejects as unsafe.
        #expect(throws: (any Error).self) {
            try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        }
        #expect(try Data(contentsOf: real) == data)
        #expect(fixture.homeURLs().isEmpty)
    }

    @Test
    func `identical re-import is idempotent and returns the existing account`() throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "dup@example.com", accountID: "ws")
        let first = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        let second = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        #expect(second.outcome == .existing)
        #expect(second.id == first.id)
        #expect(try fixture.store.loadAccounts().accounts.count == 1)
        #expect(fixture.homeURLs().count == 1)
    }

    @Test(arguments: [true, false])
    func `different credentials for an existing account fail without overwriting`(sourceRefreshed: Bool) throws {
        let fixture = try ImportFixture()
        let original = try fixture.writeSource(email: "dup@example.com", accountID: "ws")
        let first = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        let account = try #require(fixture.store.loadAccounts().account(id: first.id))
        let managedAuth = CodexAuthFingerprint.authFileURL(homePath: account.managedHomePath)
        let refreshed = ImportFixture.authJSON(email: "dup@example.com", accountID: "ws", suffix: "refreshed")
        if sourceRefreshed { try refreshed.write(to: fixture.sourceAuth) } else { try refreshed.write(to: managedAuth) }
        let registryBefore = try Data(contentsOf: fixture.storeURL)

        #expect(throws: CodexManagedAccountImportError.accountExists) {
            try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        }
        #expect(try Data(contentsOf: managedAuth) == (sourceRefreshed ? original : refreshed))
        #expect(try Data(contentsOf: fixture.sourceAuth) == (sourceRefreshed ? refreshed : original))
        #expect(try Data(contentsOf: fixture.storeURL) == registryBefore)
        #expect(fixture.homeURLs().count == 1)
    }

    @Test
    func `same email in another workspace and other accounts are preserved`() throws {
        let fixture = try ImportFixture()
        let other = try fixture.seedExistingAccount(email: "same@example.com", accountID: "ws-1")
        _ = try fixture.writeSource(email: "same@example.com", accountID: "ws-2")
        let receipt = try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        let accounts = try fixture.store.loadAccounts().accounts
        #expect(accounts.map(\.id) == [other.id, receipt.id])
        #expect(try Data(contentsOf: CodexAuthFingerprint.authFileURL(homePath: other.managedHomePath))
            == ImportFixture.authJSON(email: "same@example.com", accountID: "ws-1"))
    }

    @Test
    func `legacy email-only record blocks a shadowing import`() throws {
        let fixture = try ImportFixture()
        let home = fixture.managedHomes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try fixture.store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: [ManagedCodexAccount(
            id: UUID(), email: "legacy@example.com", managedHomePath: home.path,
            createdAt: 0, updatedAt: 0, lastAuthenticatedAt: nil)]))
        _ = try fixture.writeSource(email: "legacy@example.com", accountID: "ws")
        #expect(throws: CodexManagedAccountImportError.accountExists) {
            try fixture.transaction().importProfile(fromHome: fixture.sourceHome)
        }
        #expect(fixture.homeURLs().map(\.lastPathComponent) == [home.lastPathComponent])
    }

    @Test
    func `registry save failure removes only the new home and keeps existing accounts`() throws {
        let fixture = try ImportFixture()
        let existing = try fixture.seedExistingAccount()
        let registryBefore = try Data(contentsOf: fixture.storeURL)
        _ = try fixture.writeSource(email: "new@example.com", accountID: "ws-new")
        struct Injected: Error {}
        let failing = RecordingManagedCodexAccountStore(base: fixture.store, onStore: { _ in throw Injected() })
        #expect(throws: CodexManagedAccountImportError.registryCommitFailed) {
            try fixture.transaction(store: failing).importProfile(fromHome: fixture.sourceHome)
        }
        #expect(try Data(contentsOf: fixture.storeURL) == registryBefore)
        #expect(fixture.homeURLs().map(\.lastPathComponent) == [existing.id.uuidString])
        #expect(FileManager.default.fileExists(atPath: fixture.sourceAuth.path))
    }

    @Test
    func `home survives when save persists then throws and the registry cannot be reloaded`() throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "new@example.com", accountID: "ws-new")
        let store = PersistThenFailStore(base: fixture.store)
        #expect(throws: CodexManagedAccountImportError.registryCommitFailed) {
            try fixture.transaction(store: store).importProfile(fromHome: fixture.sourceHome)
        }
        #expect(store.storeCalls == 1)
        let accounts = try fixture.store.loadAccounts().accounts
        #expect(accounts.count == 1)
        let home = try #require(accounts.first).managedHomePath
        #expect(fixture.homeURLs().map(\.lastPathComponent) == [URL(fileURLWithPath: home).lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: CodexAuthFingerprint.authFileURL(homePath: home).path))
    }

    @Test(arguments: ["outside", "not-a-uuid", "collision"])
    func `unsafe managed home locations are refused before any write`(kind: String) throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "new@example.com", accountID: "ws")
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let colliding = fixture.managedHomes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chosen: URL = switch kind {
        case "outside": outside.appendingPathComponent(UUID().uuidString, isDirectory: true)
        case "not-a-uuid": fixture.managedHomes.appendingPathComponent("plain", isDirectory: true)
        default: colliding
        }
        if kind == "collision" {
            try FileManager.default.createDirectory(at: colliding, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: colliding.appendingPathComponent("keep"))
        }
        let factory = FixedHomeFactory(root: fixture.managedHomes, home: chosen)
        #expect(throws: (any Error).self) {
            try fixture.transaction(homeFactory: factory).importProfile(fromHome: fixture.sourceHome)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(try fixture.store.loadAccounts().accounts.isEmpty)
        if kind == "collision" {
            #expect(try Data(contentsOf: colliding.appendingPathComponent("keep")) == Data("keep".utf8))
        }
    }

    @Test
    func `source auth is read exactly once and no other probe is configured`() throws {
        let fixture = try ImportFixture()
        _ = try fixture.writeSource(email: "once@example.com", accountID: "ws")
        let reader = CountingReader()
        _ = try fixture.transaction(reader: reader).importProfile(fromHome: fixture.sourceHome)
        #expect(reader.reads == 1)
    }

    @Test
    func `import command parses and does not change list or promote`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let invocation = try program.resolve(argv: ["codex-accounts", "import", "--from-home", "/tmp/x", "--json"])
        #expect(invocation.path == ["codex-accounts", "import"])
        #expect(invocation.parsedValues.options["fromHome"]?.last == "/tmp/x")
        #expect(try program.resolve(argv: ["codex-accounts"]).path == ["codex-accounts", "list"])
        let help = CodexBarCLI.codexAccountsHelp(version: "synthetic")
        #expect(help.contains("import --from-home"))
        #expect(help.contains("0600"))
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }
}

/// First load works; the save really persists and then throws; every later load throws.
private final class PersistThenFailStore: ManagedCodexAccountStoring, @unchecked Sendable {
    struct Failure: Error {}
    let base: any ManagedCodexAccountStoring
    private(set) var storeCalls = 0
    private var loads = 0
    var lockURL: URL? { self.base.lockURL }
    init(base: any ManagedCodexAccountStoring) { self.base = base }
    func loadAccounts() throws -> ManagedCodexAccountSet {
        self.loads += 1
        guard self.loads == 1 else { throw Failure() }
        return try self.base.loadAccounts()
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        self.storeCalls += 1
        try self.base.storeAccounts(accounts)
        throw Failure()
    }

    func ensureFileExists() throws -> URL { try self.base.ensureFileExists() }
}

private final class CountingReader: CodexAuthMaterialReading, @unchecked Sendable {
    private(set) var reads = 0
    func readAuthData(homeURL: URL) throws -> Data? {
        self.reads += 1
        return try CodexImportSourceAuthReader().readAuthData(homeURL: homeURL)
    }
}

private struct FixedHomeFactory: ManagedCodexHomeProducing {
    let root: URL
    let home: URL
    func makeHomeURL() -> URL { self.home }
    func validateManagedHomeForDeletion(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(self.root.standardizedFileURL.path + "/") else {
            throw CodexAccountCLIError.unsafeHome
        }
    }
}

private struct RootHomeFactory: ManagedCodexHomeProducing {
    let root: URL
    func makeHomeURL() -> URL { self.root.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    func validateManagedHomeForDeletion(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(self.root.standardizedFileURL.path + "/") else {
            throw CodexAccountCLIError.unsafeHome
        }
    }
}

@MainActor
struct ImportFixture {
    enum RejectedProfile: String, CaseIterable, CustomTestStringConvertible {
        case apiKeyOnly, noEmail, noWorkspace, malformedJSON, notAnObject, emptyRefresh, missingFile, oversized
        var testDescription: String { self.rawValue }
        var expectedError: CodexManagedAccountImportError {
            switch self {
            case .apiKeyOnly, .malformedJSON, .notAnObject, .emptyRefresh: .sourceNotOAuth
            case .noEmail: .sourceMissingEmail
            case .noWorkspace: .sourceMissingWorkspaceIdentity
            case .missingFile: .sourceAuthMissing
            case .oversized: .sourceAuthTooLarge
            }
        }
    }

    let root: URL
    let sourceHome: URL
    let liveHome: URL
    let managedHomes: URL
    let storeURL: URL
    let store: FileManagedCodexAccountStore
    let homeFactory: any ManagedCodexHomeProducing

    var sourceAuth: URL { self.sourceHome.appendingPathComponent("auth.json") }
    var liveAuth: URL { self.liveHome.appendingPathComponent("auth.json") }

    init() throws {
        self.root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.sourceHome = self.root.appendingPathComponent("profile", isDirectory: true)
        self.liveHome = self.root.appendingPathComponent("live", isDirectory: true)
        self.managedHomes = self.root.appendingPathComponent("managed-codex-homes", isDirectory: true)
        self.storeURL = self.root.appendingPathComponent("managed-codex-accounts.json")
        self.store = FileManagedCodexAccountStore(fileURL: self.storeURL)
        self.homeFactory = RootHomeFactory(root: self.managedHomes)
        try FileManager.default.createDirectory(at: self.managedHomes, withIntermediateDirectories: true)
        _ = try self.store.ensureFileExists()
    }

    func transaction(
        store: (any ManagedCodexAccountStoring)? = nil,
        homeFactory: (any ManagedCodexHomeProducing)? = nil,
        reader: (any CodexAuthMaterialReading)? = nil) -> CodexManagedAccountImportTransaction
    {
        CodexManagedAccountImportTransaction(
            store: store ?? self.store,
            homeFactory: homeFactory ?? self.homeFactory,
            authMaterialReader: reader ?? CodexImportSourceAuthReader(),
            now: { Date(timeIntervalSince1970: 1000) })
    }

    func homeURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: self.managedHomes, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func writeSource(email: String, accountID: String) throws -> Data {
        try self.write(Self.authJSON(email: email, accountID: accountID), to: self.sourceHome)
    }

    @discardableResult
    func writeLive(email: String, accountID: String) throws -> Data {
        try self.write(Self.authJSON(email: email, accountID: accountID), to: self.liveHome)
    }

    @discardableResult
    func write(_ data: Data, to home: URL) throws -> Data {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try data.write(to: home.appendingPathComponent("auth.json"))
        return data
    }

    @discardableResult
    func seedExistingAccount(email: String = "existing@example.com", accountID: String = "ws-existing")
        throws -> ManagedCodexAccount
    {
        let id = UUID()
        let home = self.managedHomes.appendingPathComponent(id.uuidString, isDirectory: true)
        let data = Self.authJSON(email: email, accountID: accountID)
        try self.write(data, to: home)
        let account = ManagedCodexAccount(
            id: id, email: email, providerAccountID: accountID, workspaceAccountID: accountID,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: data), managedHomePath: home.path,
            createdAt: 1, updatedAt: 1, lastAuthenticatedAt: 1)
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: self.store.loadAccounts().accounts + [account]))
        return account
    }

    func writeRejected(_ profile: RejectedProfile) throws {
        switch profile {
        case .apiKeyOnly:
            try self.write(Data(#"{"OPENAI_API_KEY":"sk-synthetic"}"#.utf8), to: self.sourceHome)
        case .noEmail:
            try self.write(Self.authJSON(email: nil, accountID: "ws"), to: self.sourceHome)
        case .noWorkspace:
            try self.write(Self.authJSON(email: "a@example.com", accountID: nil), to: self.sourceHome)
        case .malformedJSON:
            try self.write(Data("{not json".utf8), to: self.sourceHome)
        case .notAnObject:
            try self.write(Data("[]".utf8), to: self.sourceHome)
        case .emptyRefresh:
            try self.write(
                Self.authJSON(email: "a@example.com", accountID: "ws", refreshToken: ""),
                to: self.sourceHome)
        case .missingFile:
            try FileManager.default.createDirectory(at: self.sourceHome, withIntermediateDirectories: true)
        case .oversized:
            try self.write(
                Data(repeating: 0x20, count: CodexImportSourceAuthReader.maximumBytes + 1),
                to: self.sourceHome)
        }
    }

    static func authJSON(
        email: String?,
        accountID: String?,
        suffix: String = "token",
        refreshToken: String? = nil) -> Data
    {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        var claims: [String: Any] = [:]
        if let email { claims["email"] = email }
        var authClaims: [String: Any] = ["chatgpt_plan_type": "pro"]
        if let accountID { authClaims["chatgpt_account_id"] = accountID }
        claims["https://api.openai.com/auth"] = authClaims
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"], options: [.sortedKeys])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data()
        let tokens: [String: Any] = [
            "access_token": "access-\(suffix)",
            "refresh_token": refreshToken ?? "refresh-\(suffix)",
            "id_token": "\(base64URL(header)).\(base64URL(payload)).",
        ]
        return (try? JSONSerialization.data(
            withJSONObject: ["tokens": tokens, "last_refresh": "2026-04-05T00:00:00Z"],
            options: [.sortedKeys])) ?? Data()
    }

    static func authJSON(email: String, accountID: String) -> Data {
        self.authJSON(email: email as String?, accountID: accountID as String?)
    }
}
