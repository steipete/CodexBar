import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIClaudePlatformLoginTests {
    @Test
    func `login requires explicit stdin and rejects malformed candidates before fetching`() throws {
        for alias in ["claudeplatform", "claude-platform"] {
            #expect(try CodexBarCLI.configLoginProvider(alias, readFromStdin: true) == .claudeplatform)
            #expect(throws: CLIArgumentError.self) {
                try CodexBarCLI.configLoginProvider(alias, readFromStdin: false)
            }
        }
        #expect(try CodexBarCLI.configLoginProvider("copilot", readFromStdin: false) == .copilot)
        for provider in [nil, "unknown", "claude", "copilot"] {
            #expect(throws: CLIArgumentError.self) {
                try CodexBarCLI.configLoginProvider(provider, readFromStdin: true)
            }
        }
        for header in [nil, " ", "sessionKey=", "other=sentinel", "sessionKey=sentinel\nother=value"] {
            #expect(throws: CLIArgumentError.self) { try CodexBarCLI.claudePlatformLoginCookie(header) }
        }
        #expect(try CodexBarCLI.claudePlatformLoginCookie(" Cookie: sessionKey=synthetic-candidate\n")
            == "sessionKey=synthetic-candidate")
    }

    @Test
    func `validated zero balance saves only the supplied candidate despite optional spend failure`() async throws {
        let store = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let fixture = Fixture(spendStatus: 401)
        var events: [String] = []
        try await CodexBarCLI.loginClaudePlatform(
            cookieHeader: "Cookie: \(Self.candidate)", store: store, transport: fixture)
        { event in
            events.append(CodexBarCLI.encodeJSON(event, pretty: false) ?? "")
            #expect((try? store.load()?.providerConfig(for: .claudeplatform)?.cookieHeader) == Self.candidate)
        }
        #expect(events == [#"{"status":"authorized"}"#])
        let saved = try #require(store.load()?.providerConfig(for: .claudeplatform))
        #expect(saved.cookieSource == .manual)
        #expect(saved.enabled == true)
        #expect(try store.load()?.providerConfig(for: .copilot)?.tokenAccounts?.accounts.first?.token
            == "preserved-account")
        #expect(await fixture.paths == [
            "/api/organizations", "/api/organizations/fixture-api/prepaid/credits",
            "/api/organizations/fixture-api/current_spend",
        ])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.first { $0["id"] as? String == "claudeplatform" }?["futureField"] as? [String: Bool]
            == ["keep": true])
        #expect(providers.first { $0["id"] as? String == "future-provider" }?["opaque"] as? String == "keep")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func `rejected replacement never falls back to saved cookie or emits the candidate`() async throws {
        let store = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.fileURL)
        let fixture = Fixture(organizationsStatus: 401)
        var events: [String] = []
        do {
            try await CodexBarCLI.loginClaudePlatform(
                cookieHeader: Self.candidate, store: store, transport: fixture)
            { events.append($0.status) }
            Issue.record("Invalid replacement unexpectedly succeeded")
        } catch {
            #expect((error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
            #expect(!error.localizedDescription.contains("synthetic-candidate"))
            #expect(!error.localizedDescription.contains("upstream-private-response"))
        }
        #expect(events.isEmpty)
        #expect(await fixture.paths == ["/api/organizations"])
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    @Test
    func `validation does not overwrite a concurrent config edit`() async throws {
        let store = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let fixture = Fixture(onOrganizations: {
            let original = try store.load()
            let changed = try CodexBarCLI.configSettingCookie(
                #require(original),
                provider: .claudeplatform,
                cookieHeader: "sessionKey=concurrent-change",
                enableProvider: false)
            try store.save(changed)
        })
        var events: [String] = []
        do {
            try await CodexBarCLI.loginClaudePlatform(
                cookieHeader: Self.candidate, store: store, transport: fixture)
            { events.append($0.status) }
            Issue.record("Concurrent edit unexpectedly overwritten")
        } catch {
            #expect(error.localizedDescription == "Config changed during login. Please try again.")
        }
        #expect(events.isEmpty)
        #expect(try store.load()?.providerConfig(for: .claudeplatform)?.cookieHeader == "sessionKey=concurrent-change")
    }

    @Test
    func `cancelled optional request preserves the previous session`() async throws {
        let store = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.fileURL)
        var events: [String] = []
        await #expect(throws: CancellationError.self) {
            try await CodexBarCLI.loginClaudePlatform(
                cookieHeader: Self.candidate, store: store, transport: Fixture(cancelSpend: true))
            { events.append($0.status) }
        }
        #expect(events.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    @Test
    func `failed private publish does not authorize or replace the previous session`() async throws {
        let store = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.fileURL)
        let fixture = Fixture(onOrganizations: {
            let lockURL = store.fileURL.appendingPathExtension("lock")
            try FileManager.default.removeItem(at: lockURL)
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        })
        var events: [String] = []
        await #expect(throws: POSIXError.self) {
            try await CodexBarCLI.loginClaudePlatform(cookieHeader: Self.candidate, store: store, transport: fixture)
                { events.append($0.status) }
        }
        #expect(events.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    private static let candidate = "sessionKey=synthetic-candidate"

    private static func temporaryStore() throws -> CodexBarConfigStore {
        let store = CodexBarConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("console-login-\(UUID())/config.json"))
        try store.save(CodexBarConfig.decode(from: Data("""
        {"version":1,"providers":[{"id":"claudeplatform","enabled":false,"cookieSource":"auto",
         "cookieHeader":"sessionKey=previous-session","futureField":{"keep":true}},
         {"id":"future-provider","opaque":"keep"},
         {"id":"copilot","tokenAccounts":{"version":1,"activeIndex":0,"accounts":[
          {"id":"00000000-0000-0000-0000-000000000001","label":"Synthetic","token":"preserved-account","addedAt":1}]}}]}
        """.utf8)))
        return store
    }

    private actor Fixture: ProviderHTTPTransport {
        var paths: [String] = []
        let organizationsStatus: Int
        let spendStatus: Int
        let cancelSpend: Bool
        let onOrganizations: (@Sendable () throws -> Void)?

        init(
            organizationsStatus: Int = 200,
            spendStatus: Int = 200,
            cancelSpend: Bool = false,
            onOrganizations: (@Sendable () throws -> Void)? = nil)
        {
            self.organizationsStatus = organizationsStatus
            self.spendStatus = spendStatus
            self.cancelSpend = cancelSpend
            self.onOrganizations = onOrganizations
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.host == "platform.claude.com")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == CLIClaudePlatformLoginTests.candidate)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            self.paths.append(url.path)
            let code: Int
            let body: String
            switch url.path {
            case "/api/organizations":
                try self.onOrganizations?()
                code = self.organizationsStatus
                body = code == 200
                    ? #"[{"uuid":"fixture-api","capabilities":["api"]}]"# : "upstream-private-response"
            case "/api/organizations/fixture-api/prepaid/credits":
                code = 200
                body = #"{"amount":0,"currency":"USD"}"#
            case "/api/organizations/fixture-api/current_spend":
                if self.cancelSpend { throw CancellationError() }
                code = self.spendStatus
                body = #"{"amount":0}"#
            default:
                Issue.record("Unexpected request")
                throw URLError(.badURL)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
        }
    }
}
