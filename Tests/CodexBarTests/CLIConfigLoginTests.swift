import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigLoginTests {
    @Test
    func `config login resolves provider and JSON options`() throws {
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(argv: ["config", "login", "--provider", "copilot", "--json"])
        #expect(invocation.path == ["config", "login"])
        #expect(invocation.parsedValues.options["provider"] == ["copilot"])
        #expect(CLIOutputPreferences.from(values: invocation.parsedValues).format == .json)
    }

    @Test
    func `login persists a reusable account before emitting token free success`() async throws {
        let store = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var events: [String] = []
        try await CodexBarCLI.loginCopilot(store: store, transport: Self.transport()) { event in
            let raw = Data((CodexBarCLI.encodeJSON(event, pretty: false) ?? "").utf8)
            let object = (try? JSONSerialization.jsonObject(with: raw)) ?? [:]
            let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            events.append(String(data: canonical ?? Data(), encoding: .utf8) ?? "")
            if event.status == "authorized" {
                #expect((try? store.load()?.providerConfig(for: .copilot)?.tokenAccounts?.accounts.count) == 1)
            }
        }
        #expect(events == [
            #"{"expiresIn":900,"status":"authorization_pending","userCode":"ABCD-EFGH","verificationURI":"https://github.com/login/device"}"#,
            #"{"status":"authorized"}"#,
        ])
        let saved = try #require(store.load()?.providerConfig(for: .copilot))
        let account = try #require(saved.tokenAccounts?.accounts.first)
        #expect(saved.enabled == true)
        #expect(saved.apiKey == nil)
        #expect(account.externalIdentifier == "github:user:42")
        #expect(account.token == "synthetic-device-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await CodexBarCLI.loginCopilot(store: store, transport: Self.transport()) { _ in }
        let refreshed = try #require(store.load()?.providerConfig(for: .copilot)?.tokenAccounts)
        #expect(refreshed.accounts.count == 1)
        #expect(refreshed.accounts.first?.id == account.id)
    }

    @Test
    func `login refuses config changes made during authorization`() async throws {
        let store = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var events: [String] = []
        do {
            try await CodexBarCLI.loginCopilot(store: store, transport: Self.transport()) { event in
                events.append(event.status)
                if event.status == "authorization_pending" {
                    var config = CodexBarConfig.makeDefault()
                    config.setProviderConfig(ProviderConfig(id: .copilot, enterpriseHost: "example.ghe.com"))
                    try? store.save(config)
                }
            }
            Issue.record("Expected concurrent config edit to reject login")
        } catch {
            #expect(error.localizedDescription == "Config changed during login. Please try again.")
        }
        #expect(events == ["authorization_pending"])
        #expect(try store.load()?.providerConfig(for: .copilot)?.enterpriseHost == "example.ghe.com")
        #expect(try store.load()?.providerConfig(for: .copilot)?.tokenAccounts == nil)
    }

    @Test
    func `failed token polling leaves config untouched and never emits success`() async throws {
        let store = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var events: [String] = []
        await #expect(throws: URLError(.userCancelledAuthentication)) {
            try await CodexBarCLI.loginCopilot(
                store: store, transport: Self.transport(tokenResponse: #"{"error":"access_denied"}"#))
            { events.append($0.status) }
        }
        #expect(events == ["authorization_pending"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test
    func `enterprise login keeps the public account with the same numeric ID`() async throws {
        let store = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let publicAccount = ProviderTokenAccount(
            id: UUID(),
            label: "Personal",
            token: "public-fixture",
            addedAt: 1,
            lastUsed: nil,
            externalIdentifier: "github:user:42")
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(
            id: .copilot,
            enterpriseHost: "example.ghe.com",
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [publicAccount], activeIndex: 0)))
        try store.save(config)
        try await CodexBarCLI.loginCopilot(store: store, transport: Self.transport(host: "example.ghe.com")) { _ in }
        let accounts = try #require(store.load()?.providerConfig(for: .copilot)?.tokenAccounts)
        #expect(accounts.accounts.count == 2)
        #expect(accounts.accounts[0].token == "public-fixture")
        #expect(accounts.accounts[1].externalIdentifier == "github:api.example.ghe.com:user:42")
        #expect(accounts.activeIndex == 1)
    }

    @Test
    func `storage failure never emits success`() async throws {
        let store = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var events: [String] = []
        do {
            try await CodexBarCLI.loginCopilot(store: store, transport: Self.transport()) { event in
                events.append(event.status)
                if event.status == "authorization_pending" {
                    try? FileManager.default.createDirectory(
                        at: store.fileURL.appendingPathExtension("lock"), withIntermediateDirectories: true)
                }
            }
            Issue.record("Expected storage failure")
        } catch {
            #expect(error is POSIXError)
        }
        #expect(events == ["authorization_pending"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    private static func temporaryStore() -> CodexBarConfigStore {
        CodexBarConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-login-\(UUID().uuidString)/config.json"))
    }

    private static func transport(
        host: String = "github.com",
        tokenResponse: String = #"{"access_token":"synthetic-device-token","token_type":"bearer","scope":"read:user"}"#)
        -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.host == (url.path == "/user" ? "api.\(host)" : host))
            let body: String
            switch url.path {
            case "/login/device/code":
                body = """
                {"device_code":"synthetic-device-code","user_code":"ABCD-EFGH",
                 "verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}
                """
            case "/login/oauth/access_token":
                body = tokenResponse
            case "/user":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "token synthetic-device-token")
                body = #"{"id":42,"login":"octocat"}"#
            default:
                Issue.record("Unexpected request")
                throw URLError(.badURL)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}
