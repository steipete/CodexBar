@testable import CodexBarCore
import Foundation
import Testing

struct ImportedCredentialsTests {
    @Test
    func `legacy config without imported credential sources decodes to empty list`() throws {
        let legacyJSON = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "codex"
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(legacyJSON.utf8))

        #expect(decoded.importedCredentialSources.isEmpty)
    }

    @Test
    func `config store round trips imported credential sources`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let sourceID = UUID()

        try store.save(CodexBarConfig(
            providers: [ProviderConfig(id: .codex)],
            importedCredentialSources: [
                ImportedCredentialSource(
                    id: sourceID,
                    platform: "codex",
                    path: "/tmp/imported-codex",
                    format: CLIProxyCodexAdapter.format,
                    label: "Work"),
            ]))

        let loadedConfig = try store.load()
        let reloaded = try #require(loadedConfig)
        let source = try #require(reloaded.importedCredentialSources.first)
        #expect(reloaded.importedCredentialSources.count == 1)
        #expect(source.id == sourceID)
        #expect(source.platform == "codex")
        #expect(source.path == "/tmp/imported-codex")
        #expect(source.format == CLIProxyCodexAdapter.format)
        #expect(source.label == "Work")
    }

    @Test
    func `cliproxyapi codex file converts flat credentials to codex oauth credentials`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("codex-primary.json")
        try Self.writeCLIProxyCodexFile(
            to: file,
            email: "user@example.com",
            accountID: "account-123",
            accessToken: "access-token",
            idToken: "id-token",
            refreshToken: "refresh-token",
            lastRefresh: "2026-06-10T14:11:59+09:00",
            expired: "2026-06-22T14:11:59+09:00")

        let accounts = CLIProxyCodexAdapter.loadAccounts(
            from: file.path,
            now: try Self.date("2026-06-14T00:00:00Z"))
        let account = try #require(accounts.first)

        #expect(accounts.count == 1)
        #expect(account.email == "user@example.com")
        #expect(account.accountId == "account-123")
        #expect(account.id.hasPrefix("borrowed:account-123:"))
        #expect(account.id.count == "borrowed:account-123:".count + 64)
        #expect(account.credentials.accessToken == "access-token")
        #expect(account.credentials.accountId == "account-123")
        #expect(account.credentials.idToken == "id-token")
        #expect(account.credentials.refreshToken == "refresh-token")
    }

    @Test
    func `cliproxyapi account id includes source path hash`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("codex-plus.json")
        let second = directory.appendingPathComponent("codex-team.json")
        try Self.writeCLIProxyCodexFile(
            to: first,
            email: "plus@example.com",
            accountID: "shared-account")
        try Self.writeCLIProxyCodexFile(
            to: second,
            email: "team@example.com",
            accountID: "shared-account")

        let accounts = CLIProxyCodexAdapter.loadAccounts(
            from: directory.path,
            now: try Self.date("2026-06-14T00:00:00Z"))

        #expect(accounts.count == 2)
        #expect(Set(accounts.map(\.accountId)) == ["shared-account"])
        #expect(Set(accounts.map(\.id)).count == 2)
        #expect(accounts.allSatisfy { $0.id.hasPrefix("borrowed:shared-account:") })
    }

    @Test
    func `cliproxyapi directory scan keeps codex json files and skips sidecars disabled and malformed entries`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-active.json"),
            email: "active@example.com",
            accountID: "account-active")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-disabled.json"),
            email: "disabled@example.com",
            accountID: "account-disabled",
            disabled: true)
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-not-codex.json"),
            type: "claude",
            email: "other@example.com",
            accountID: "account-other")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-sidecar.json.bak"),
            email: "bak@example.com",
            accountID: "account-bak")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-sidecar.json.dead-rt123"),
            email: "dead@example.com",
            accountID: "account-dead")
        try "not json".write(
            to: directory.appendingPathComponent("codex-bad.json"),
            atomically: true,
            encoding: .utf8)

        let accounts = CLIProxyCodexAdapter.loadAccounts(
            from: directory.path,
            now: try Self.date("2026-06-14T00:00:00Z"))

        #expect(accounts.map(\.email) == ["active@example.com"])
        #expect(accounts.map(\.accountId) == ["account-active"])
    }

    @Test
    func `cliproxyapi direct file import applies codex json filename filter`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("codex-valid.json")
        let sidecar = directory.appendingPathComponent("codex-valid.json.dead-rt123")
        let nonCodexJSON = directory.appendingPathComponent("manual.json")
        try Self.writeCLIProxyCodexFile(
            to: valid,
            email: "valid@example.com",
            accountID: "account-valid")
        try Self.writeCLIProxyCodexFile(
            to: sidecar,
            email: "sidecar@example.com",
            accountID: "account-sidecar")
        try Self.writeCLIProxyCodexFile(
            to: nonCodexJSON,
            email: "manual@example.com",
            accountID: "account-manual")

        let now = try Self.date("2026-06-14T00:00:00Z")

        #expect(CLIProxyCodexAdapter.loadAccounts(from: sidecar.path, now: now).isEmpty)
        #expect(CLIProxyCodexAdapter.previewAccounts(from: sidecar.path, now: now).isEmpty)
        #expect(CLIProxyCodexAdapter.loadAccounts(from: nonCodexJSON.path, now: now).isEmpty)
        #expect(CLIProxyCodexAdapter.previewAccounts(from: nonCodexJSON.path, now: now).isEmpty)
        #expect(CLIProxyCodexAdapter.loadAccounts(from: valid.path, now: now).map(\.email) == ["valid@example.com"])
        #expect(CLIProxyCodexAdapter.previewAccounts(from: valid.path, now: now).map(\.email) == ["valid@example.com"])
    }

    @Test
    func `cliproxyapi preview includes disabled and expired account statuses`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-active.json"),
            email: "active@example.com",
            accountID: "account-active",
            expired: "2026-06-22T14:11:59+09:00")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-disabled.json"),
            email: "disabled@example.com",
            accountID: "account-disabled",
            expired: "2026-06-22T14:11:59+09:00",
            disabled: true)
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-expired.json"),
            email: "expired@example.com",
            accountID: "account-expired",
            expired: "2026-06-13T00:00:00Z")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-not-codex.json"),
            type: "claude",
            email: "other@example.com",
            accountID: "account-other")

        let previews = CLIProxyCodexAdapter.previewAccounts(
            from: directory.path,
            now: try Self.date("2026-06-14T00:00:00Z"))
        let byEmail = Dictionary(uniqueKeysWithValues: previews.map { ($0.email, $0) })

        #expect(previews.map(\.email).sorted() == [
            "active@example.com",
            "disabled@example.com",
            "expired@example.com",
        ])
        #expect(byEmail["active@example.com"]?.isDisabled == false)
        #expect(byEmail["active@example.com"]?.isExpired == false)
        #expect(byEmail["disabled@example.com"]?.isDisabled == true)
        #expect(byEmail["expired@example.com"]?.isExpired == true)
    }

    @Test
    func `cliproxyapi expiration is computed against injected date`() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-past.json"),
            email: "past@example.com",
            accountID: "account-past",
            expired: "2026-06-13T23:59:59Z")
        try Self.writeCLIProxyCodexFile(
            to: directory.appendingPathComponent("codex-future.json"),
            email: "future@example.com",
            accountID: "account-future",
            expired: "2026-06-15T00:00:00Z")

        let accounts = CLIProxyCodexAdapter.loadAccounts(
            from: directory.path,
            now: try Self.date("2026-06-14T00:00:00Z"))
        let states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.email, $0.isExpired) })

        #expect(states["past@example.com"] == true)
        #expect(states["future@example.com"] == false)
    }

    @Test
    func `borrowed codex usage fetcher rejects expired accounts before network`() async throws {
        let account = BorrowedCodexAccount(
            id: "borrowed:account-expired:path",
            email: "expired@example.com",
            accountId: "account-expired",
            credentials: CodexOAuthCredentials(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                idToken: nil,
                accountId: "account-expired",
                lastRefresh: nil),
            expired: try Self.date("2026-06-13T00:00:00Z"),
            isExpired: true,
            sourcePath: "/tmp/codex-expired.json")

        await #expect(throws: BorrowedCredentialError.expired(accountID: account.id)) {
            _ = try await BorrowedCodexUsageFetcher.fetchUsage(
                account: account,
                updatedAt: try Self.date("2026-06-14T00:00:00Z"))
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedCredentialsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeCLIProxyCodexFile(
        to url: URL,
        type: String = "codex",
        email: String,
        accountID: String,
        accessToken: String = "access-token",
        idToken: String = "id-token",
        refreshToken: String = "refresh-token",
        lastRefresh: String = "2026-06-10T14:11:59+09:00",
        expired: String = "2026-06-22T14:11:59+09:00",
        disabled: Bool = false) throws
    {
        let object: [String: Any] = [
            "type": type,
            "email": email,
            "account_id": accountID,
            "access_token": accessToken,
            "id_token": idToken,
            "refresh_token": refreshToken,
            "last_refresh": lastRefresh,
            "expired": expired,
            "disabled": disabled,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
