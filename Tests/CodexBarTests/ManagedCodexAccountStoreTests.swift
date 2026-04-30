import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Test
func `FileManagedCodexAccountStore round trip`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let firstID = UUID()
    let secondID = UUID()
    let firstAccount = ManagedCodexAccount(
        id: firstID,
        email: "  FIRST@Example.COM ",
        providerAccountID: "account-first",
        managedHomePath: "/tmp/managed-home-1",
        createdAt: 1000,
        updatedAt: 2000,
        lastAuthenticatedAt: 3000)
    let secondAccount = ManagedCodexAccount(
        id: secondID,
        email: "second@example.com",
        providerAccountID: "account-second",
        managedHomePath: "/tmp/managed-home-2",
        createdAt: 4000,
        updatedAt: 5000,
        lastAuthenticatedAt: nil)
    let payload = ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: [firstAccount, secondAccount])
    let store = FileManagedCodexAccountStore(fileURL: fileURL)

    try store.storeAccounts(payload)
    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let loaded = try store.loadAccounts()
    let accountsRange = try #require(contents.range(of: "\"accounts\""))
    let versionRange = try #require(contents.range(of: "\"version\""))

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.count == 2)
    #expect(loaded.accounts[0].email == "first@example.com")
    #expect(loaded.accounts[0].providerAccountID == "account-first")
    #expect(loaded.account(id: firstID)?.managedHomePath == "/tmp/managed-home-1")
    #expect(loaded.account(email: "SECOND@example.com", providerAccountID: "account-second")?.id == secondID)
    #expect(contents.contains("\n  \"accounts\""))
    #expect(accountsRange.lowerBound < versionRange.lowerBound)
    #expect(contents.contains("\"activeAccountID\"") == false)
}

@Test
func `FileManagedCodexAccountStore missing file loads empty set`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-nil-active-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try? FileManager.default.removeItem(at: fileURL)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let initial = try store.loadAccounts()

    #expect(initial.version == FileManagedCodexAccountStore.currentVersion)
    #expect(initial.accounts.isEmpty)

    let account = ManagedCodexAccount(
        id: UUID(),
        email: "user@example.com",
        managedHomePath: "/tmp/managed-home",
        createdAt: 10,
        updatedAt: 20,
        lastAuthenticatedAt: nil)
    let payload = ManagedCodexAccountSet(
        version: 1,
        accounts: [account])

    try store.storeAccounts(payload)
    let loaded = try store.loadAccounts()

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.count == 1)
    #expect(loaded.account(email: "USER@example.com")?.id == account.id)
}

@Test
func `FileManagedCodexAccountStore canonicalizes decoded emails`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-decode-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let accountID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "  MIXED@Example.COM  ",
          "id" : "\(accountID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home",
          "updatedAt" : 20
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.first?.email == "mixed@example.com")
    #expect(loaded.account(email: "mixed@example.com")?.id == accountID)
}

@Test
func `FileManagedCodexAccountStore drops duplicate canonical emails on load`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-duplicate-email-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let firstID = UUID()
    let secondID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : " First@Example.com ",
          "id" : "\(firstID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home-1",
          "updatedAt" : 20
        },
        {
          "createdAt" : 30,
          "email" : "first@example.com",
          "id" : "\(secondID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home-2",
          "updatedAt" : 40
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.id == firstID)
    #expect(loaded.accounts.first?.managedHomePath == "/tmp/managed-home-1")
}

@Test
func `FileManagedCodexAccountStore keeps same email rows when hydrated provider account I Ds differ`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("managed.json", isDirectory: false)
    let firstHome = root.appendingPathComponent("first-home", isDirectory: true)
    let secondHome = root.appendingPathComponent("second-home", isDirectory: true)
    try writeCodexAuthFile(homeURL: firstHome, email: "user@example.com", accountId: "account-alpha")
    try writeCodexAuthFile(homeURL: secondHome, email: "user@example.com", accountId: "account-beta")

    let firstID = UUID()
    let secondID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : " user@example.com ",
          "id" : "\(firstID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(firstHome.path)",
          "updatedAt" : 20
        },
        {
          "createdAt" : 30,
          "email" : "USER@example.com",
          "id" : "\(secondID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(secondHome.path)",
          "updatedAt" : 40
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.count == 2)
    #expect(loaded.account(email: "user@example.com", providerAccountID: "account-alpha")?.id == firstID)
    #expect(loaded.account(email: "user@example.com", providerAccountID: "account-beta")?.id == secondID)
}

@Test
func `managed account set keeps same provider account I D when emails differ`() {
    let firstID = UUID()
    let secondID = UUID()
    let first = ManagedCodexAccount(
        id: firstID,
        email: "mi.chaelfmk5542@gmail.com",
        providerAccountID: "team-4107",
        managedHomePath: "/tmp/managed-home-1",
        createdAt: 10,
        updatedAt: 20,
        lastAuthenticatedAt: nil)
    let second = ManagedCodexAccount(
        id: secondID,
        email: "mich.aelfmk5542@gmail.com",
        providerAccountID: "team-4107",
        managedHomePath: "/tmp/managed-home-2",
        createdAt: 30,
        updatedAt: 40,
        lastAuthenticatedAt: nil)

    let set = ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: [first, second])

    #expect(set.accounts.count == 2)
    #expect(set.account(email: "mi.chaelfmk5542@gmail.com", providerAccountID: "team-4107")?.id == firstID)
    #expect(set.account(email: "mich.aelfmk5542@gmail.com", providerAccountID: "team-4107")?.id == secondID)
}

@Test
func `FileManagedCodexAccountStore hydrates provider account I D from id token when account field is absent`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("managed.json", isDirectory: false)
    let home = root.appendingPathComponent("jwt-only-home", isDirectory: true)
    try writeCodexAuthFile(
        homeURL: home,
        email: "user@example.com",
        accountId: "account-jwt-only",
        includeAccountIdField: false)

    let accountID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "user@example.com",
          "id" : "\(accountID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(home.path)",
          "updatedAt" : 20
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.providerAccountID == "account-jwt-only")
    #expect(loaded.account(email: "user@example.com", providerAccountID: "account-jwt-only")?.id == accountID)
}

@Test
func `FileManagedCodexAccountStore drops duplicate IDs on load`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-duplicate-id-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let sharedID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "first@example.com",
          "id" : "\(sharedID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home-1",
          "updatedAt" : 20
        },
        {
          "createdAt" : 30,
          "email" : "second@example.com",
          "id" : "\(sharedID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home-2",
          "updatedAt" : 40
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.id == sharedID)
    #expect(loaded.accounts.first?.email == "first@example.com")
    #expect(loaded.accounts.first?.managedHomePath == "/tmp/managed-home-1")
}

@Test
func `FileManagedCodexAccountStore v1 upgrade keeps deleted home row with nil provider account I D`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let fileURL = root.appendingPathComponent("managed.json", isDirectory: false)
    let missingHome = root.appendingPathComponent("missing-home", isDirectory: true)
    let accountID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "user@example.com",
          "id" : "\(accountID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(missingHome.path)",
          "updatedAt" : 20
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.id == accountID)
    #expect(loaded.accounts.first?.providerAccountID == nil)
}

@Test
func `FileManagedCodexAccountStore ignores legacy active account key on load`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-legacy-active-key-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let accountID = UUID()
    let danglingID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "user@example.com",
          "id" : "\(accountID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home",
          "updatedAt" : 20
        }
      ],
      "activeAccountID" : "\(danglingID.uuidString)",
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()

    #expect(loaded.accounts.count == 1)
    #expect(loaded.account(id: accountID)?.email == "user@example.com")
}

@Test
func `FileManagedCodexAccountStore upgrades v1 rows and writes readable v2 file without reauth`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("managed.json", isDirectory: false)
    let firstHome = root.appendingPathComponent("first-home", isDirectory: true)
    let secondHome = root.appendingPathComponent("second-home", isDirectory: true)
    try writeCodexAuthFile(homeURL: firstHome, email: "user@example.com", accountId: "account-alpha")
    try writeCodexAuthFile(homeURL: secondHome, email: "second@example.com", accountId: "account-beta")

    let firstID = UUID()
    let secondID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "user@example.com",
          "id" : "\(firstID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(firstHome.path)",
          "updatedAt" : 20
        },
        {
          "createdAt" : 30,
          "email" : "second@example.com",
          "id" : "\(secondID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "\(secondHome.path)",
          "updatedAt" : 40
        }
      ],
      "version" : 1
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)
    let loaded = try store.loadAccounts()
    try store.storeAccounts(loaded)
    let reloaded = try store.loadAccounts()
    let contents = try String(contentsOf: fileURL, encoding: .utf8)

    #expect(loaded.accounts.count == 2)
    #expect(loaded.account(email: "user@example.com", providerAccountID: "account-alpha")?.id == firstID)
    #expect(loaded.account(email: "second@example.com", providerAccountID: "account-beta")?.id == secondID)
    #expect(reloaded.accounts.count == 2)
    #expect(contents.contains("account-alpha"))
    #expect(contents.contains("account-beta"))
    #expect(contents.contains("\"version\" : \(FileManagedCodexAccountStore.currentVersion)"))
}

@Test
func `FileManagedCodexAccountStore rejects unsupported on disk versions`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-unsupported-version-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let accountID = UUID()
    let json = """
    {
      "accounts" : [
        {
          "createdAt" : 10,
          "email" : "user@example.com",
          "id" : "\(accountID.uuidString)",
          "lastAuthenticatedAt" : null,
          "managedHomePath" : "/tmp/managed-home",
          "updatedAt" : 20
        }
      ],
      "version" : 999
    }
    """

    try json.write(to: fileURL, atomically: true, encoding: .utf8)

    let store = FileManagedCodexAccountStore(fileURL: fileURL)

    #expect(throws: FileManagedCodexAccountStoreError.unsupportedVersion(999)) {
        try store.loadAccounts()
    }
}

@Test
func `FileManagedCodexAccountStore normalizes stored version to current schema`() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-managed-codex-accounts-version-normalization-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let accountID = UUID()
    let account = ManagedCodexAccount(
        id: accountID,
        email: "user@example.com",
        providerAccountID: "account-id",
        managedHomePath: "/tmp/managed-home",
        createdAt: 10,
        updatedAt: 20,
        lastAuthenticatedAt: nil)
    let payload = ManagedCodexAccountSet(
        version: 999,
        accounts: [account])
    let store = FileManagedCodexAccountStore(fileURL: fileURL)

    try store.storeAccounts(payload)
    let loaded = try store.loadAccounts()
    let contents = try String(contentsOf: fileURL, encoding: .utf8)

    #expect(loaded.version == FileManagedCodexAccountStore.currentVersion)
    #expect(contents.contains("\"version\" : \(FileManagedCodexAccountStore.currentVersion)"))
    #expect(!contents.contains("\"version\" : 999"))
}

private func writeCodexAuthFile(
    homeURL: URL,
    email: String,
    accountId: String,
    includeAccountIdField: Bool = true) throws
{
    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    var tokens: [String: Any] = [
        "accessToken": "access-token",
        "refreshToken": "refresh-token",
        "idToken": fakeJWT(email: email, accountId: accountId),
    ]
    if includeAccountIdField {
        tokens["accountId"] = accountId
    }
    let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
    try data.write(to: homeURL.appendingPathComponent("auth.json"))
}

private func fakeJWT(email: String, accountId: String) -> String {
    let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
    let payload = (try? JSONSerialization.data(withJSONObject: [
        "email": email,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountId,
            "chatgpt_plan_type": "pro",
        ],
    ])) ?? Data()

    func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    return "\(base64URL(header)).\(base64URL(payload))."
}
