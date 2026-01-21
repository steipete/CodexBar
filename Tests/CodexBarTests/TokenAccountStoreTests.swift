import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Test("ProviderTokenAccountData encoding")
func providerTokenAccountDataEncoding() throws {
    let now = Date().timeIntervalSince1970
    let account = ProviderTokenAccount(
        id: UUID(),
        label: "user@example.com",
        token: "test-token",
        addedAt: now,
        lastUsed: now)
    let data = ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0)

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(data)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ProviderTokenAccountData.self, from: encoded)

    #expect(decoded.version == 1)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.accounts[0].label == "user@example.com")
    #expect(decoded.activeIndex == 0)
}

@Test("FileTokenAccountStore round trip")
func fileTokenAccountStoreRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
    let fileURL = tempDir.appendingPathComponent("codexbar-token-accounts-test.json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let now = Date().timeIntervalSince1970
    let account = ProviderTokenAccount(
        id: UUID(),
        label: "user@example.com",
        token: "test-token",
        addedAt: now,
        lastUsed: nil)
    let data = ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0)
    let store = FileTokenAccountStore(fileURL: fileURL)

    try store.storeAccounts([.claude: data])
    let loaded = try store.loadAccounts()

    #expect(loaded[.claude]?.accounts.count == 1)
    #expect(loaded[.claude]?.accounts[0].label == "user@example.com")
}
