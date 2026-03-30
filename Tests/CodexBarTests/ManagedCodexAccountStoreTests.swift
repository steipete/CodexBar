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
        managedHomePath: "/tmp/managed-home-1",
        createdAt: 1000,
        updatedAt: 2000,
        lastAuthenticatedAt: 3000)
    let secondAccount = ManagedCodexAccount(
        id: secondID,
        email: "second@example.com",
        managedHomePath: "/tmp/managed-home-2",
        createdAt: 4000,
        updatedAt: 5000,
        lastAuthenticatedAt: nil)
    let payload = ManagedCodexAccountSet(
        version: 1,
        accounts: [firstAccount, secondAccount])
    let store = FileManagedCodexAccountStore(fileURL: fileURL)

    try store.storeAccounts(payload)
    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let loaded = try store.loadAccounts()
    let accountsRange = try #require(contents.range(of: "\"accounts\""))
    let versionRange = try #require(contents.range(of: "\"version\""))

    #expect(loaded.version == 1)
    #expect(loaded.accounts.count == 2)
    #expect(loaded.accounts[0].email == "first@example.com")
    #expect(loaded.account(id: firstID)?.managedHomePath == "/tmp/managed-home-1")
    #expect(loaded.account(email: "SECOND@example.com")?.id == secondID)
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

    #expect(initial.version == 1)
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

    #expect(loaded.version == 1)
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
    #expect(contents.contains("\"version\" : 1"))
    #expect(!contents.contains("\"version\" : 999"))
}
