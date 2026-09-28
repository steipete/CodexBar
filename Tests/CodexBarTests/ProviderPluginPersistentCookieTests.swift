import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderPluginPersistentCookieTests {
    @TaskLocal private static var fileURL: URL?
    private let domain = "app.notion.com"

    @Test
    func `ranked domains stay in one profile and require the session cookie`() throws {
        try self.isolated { _ in
            let broker = try self.broker(records: [
                [Self.record("analytics", "skip", "app.notion.com")],
                [
                    Self.record("token_v2", "legacy", "notion.so"),
                    Self.record("token_v2", "current", "app.notion.com"),
                    Self.record("other", "from-parent", "notion.com"),
                ],
            ])
            let session = try #require(try broker.nextSession(domain: self.domain))
            #expect(try self.header(session) == "other=from-parent; token_v2=current")
            #expect(CookieHeaderCache.load(provider: .notion) == nil)
            try broker.acceptCookie(domain: self.domain, id: session.id)
            #expect(CookieHeaderCache.load(provider: .notion) != nil)
        }
    }

    @Test
    func `one validated entry survives refresh with stable identity and no cookie exposure`() throws {
        try self.isolated { _ in
            let first = try self.broker(records: [[Self.record("token_v2", "fixture", "notion.so")]])
            let session = try #require(try first.nextSession(domain: self.domain))
            #expect(CookieHeaderCache.load(provider: .notion) == nil)
            try first.acceptCookie(domain: self.domain, id: session.id)
            let next = try self.broker()
            let restored = try #require(try next.nextSession(domain: self.domain, cachedOnly: true))
            #expect(session.id != restored.id)
            #expect(session.cacheKey == restored.cacheKey)
            #expect(try self.header(restored) == "token_v2=fixture")
            #expect(try !restored.json(opaque: true).contains("fixture"))
            #expect(try next.nextSession(domain: self.domain, cachedOnly: true) == nil)
        }
    }

    @Test
    func `paired session identity is independent of browser record enumeration`() throws {
        try self.isolated { _ in
            let policy = try self.policy(provider: "zoommate", declaration: """
            cookieDomains: ['zoom.us', 'ai.zoom.us'], endpoints: ['https://ai.zoom.us'],
            cookiePolicy: {selection: 'request-url', cache: 'validated-single-entry'},
            """)
            let records = try [Self.record("first", "one", "ai.zoom.us"), Self.record("second", "two", "ai.zoom.us")]
            let keys = try [records, Array(records.reversed())].map { records in
                let broker = ProviderPluginCookieBroker(
                    provider: .zoommate,
                    domains: ["zoom.us", "ai.zoom.us"],
                    settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                    batches: { _, _ in nil },
                    jarImporter: { [.init(header: "", source: "Fixture", origin: "", records: records)] },
                    policy: policy)
                return try #require(try broker.nextSession(domain: "ai.zoom.us")).cacheKey
            }
            #expect(keys[0] == keys[1])
        }
    }

    @Test
    func `late rejection and acceptance preserve newer cache and native file`() throws {
        try self.isolated { fileURL in
            try Self.write("old", to: fileURL)
            let broker = try self.broker(background: true, fileURL: fileURL)
            let session = try #require(try broker.nextSession(domain: self.domain))
            CookieHeaderCache.store(provider: .notion, cookieHeader: "token_v2=newer", sourceLabel: "Newer")
            try Self.write("newer", to: fileURL)
            try broker.acceptCookie(domain: self.domain, id: session.id)
            broker.rejectCookie(domain: self.domain, id: session.id)
            #expect(CookieHeaderCache.load(provider: .notion)?.cookieHeader == "token_v2=newer")
            #expect(try Self.token(fileURL) == "newer")
        }
    }

    @Test
    func `native session file is first in background and is conditionally cleared on rejection`() throws {
        try self.isolated { fileURL in
            try Self.write("legacy", to: fileURL)
            let broker = try self.broker(background: true, fileURL: fileURL)
            let session = try #require(try broker.nextSession(domain: self.domain, cachedOnly: true))
            #expect(try self.header(session) == "token_v2=legacy")
            broker.rejectCookie(domain: self.domain, id: session.id)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test(arguments: [true, false])
    func `interactive refresh commits or rolls back the cache and native file together`(commit: Bool) throws {
        try self.isolated { fileURL in
            try Self.write("old", to: fileURL)
            CookieHeaderCache.store(provider: .notion, cookieHeader: "token_v2=old", sourceLabel: "Old")
            let gate = try #require(CookieHeaderCache.beginRefreshReadSuppression(provider: .notion))
            defer { CookieHeaderCache.endRefreshReadSuppression(gate) }
            let broker = try self.broker(records: [[Self.record("token_v2", "new", "notion.so")]], fileURL: fileURL)
            let session = try #require(try broker.nextSession(domain: self.domain))
            try broker.acceptCookie(domain: self.domain, id: session.id)
            #expect(try Self.token(fileURL) == "old")
            if commit {
                #expect(CookieHeaderCache.commitRefreshReadSuppression(gate).committedCount == 1)
            } else {
                CookieHeaderCache.endRefreshReadSuppression(gate)
            }
            #expect(try Self.token(fileURL) == (commit ? "new" : "old"))
            let restored = try #require(try self.broker(fileURL: fileURL).nextSession(
                domain: self.domain,
                cachedOnly: true))
            #expect(try self.header(restored) == (commit ? "token_v2=new" : "token_v2=old"))
        }
    }

    @Test
    func `failed cache commit retains the native session file`() throws {
        try self.isolated { fileURL in
            try Self.write("old", to: fileURL)
            let gate = try #require(CookieHeaderCache.beginRefreshReadSuppression(provider: .notion))
            defer { CookieHeaderCache.endRefreshReadSuppression(gate) }
            let broker = try self.broker(records: [[Self.record("token_v2", "new", "notion.so")]], fileURL: fileURL)
            let session = try #require(try broker.nextSession(domain: self.domain))
            try broker.acceptCookie(domain: self.domain, id: session.id)
            let result = KeychainCacheStore.withStoreFailureStatusOverrideForTesting(-25308) {
                CookieHeaderCache.commitRefreshReadSuppression(gate)
            }
            #expect(result.failedCount == 1)
            #expect(try Self.token(fileURL) == "old")
        }
    }

    @Test
    func `legacy paired host cache migrates without widening destinations`() throws {
        try self.isolated { _ in
            let policy = try self.policy(provider: "zoommate", declaration: """
            cookieDomains: ['zoom.us', 'ai.zoom.us', 'zoommate.zoom.us'],
            endpoints: ['https://ai.zoom.us', 'https://zoommate.zoom.us'],
            cookiePolicy: {selection: 'request-url', cache: 'validated-single-entry'},
            """)
            CookieHeaderCache.store(
                provider: .zoommate,
                cookieHeader: """
                {"headersByHost":{"ai.zoom.us":"session=ai",
                "zoommate.zoom.us":"session=mate","other.zoom.us":"session=bad"}}
                """,
                sourceLabel: "Legacy")
            let broker = ProviderPluginCookieBroker(
                provider: .zoommate,
                domains: ["zoom.us", "ai.zoom.us", "zoommate.zoom.us"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in nil },
                jarImporter: { [] },
                policy: policy)
            let session = try #require(try broker.nextSession(domain: "ai.zoom.us", cachedOnly: true))
            let jar = ProviderPluginCookieJar()
            jar.register(session)
            #expect(try jar
                .header(id: session.id, url: #require(URL(string: "https://ai.zoom.us/api"))) == "session=ai")
            #expect(try jar
                .header(id: session.id, url: #require(URL(string: "https://zoommate.zoom.us/api"))) == "session=mate")
            #expect(throws: (any Error).self) { try jar.header(
                id: session.id,
                url: #require(URL(string: "https://other.zoom.us/api"))) }
            try broker.acceptCookie(domain: "ai.zoom.us", id: session.id)
            #expect(CookieHeaderCache.load(provider: .zoommate)?.cookieHeader.contains("other.zoom.us") == false)
        }
    }

    private func policy(provider: String = "notion", declaration: String? = nil) throws -> ProviderPluginCookiePolicy {
        let declaration = declaration ?? """
        endpoints: ['https://app.notion.com'],
        cookieDomains: ['app.notion.com', 'www.notion.com', 'notion.com', 'www.notion.so', 'notion.so'],
        cookiePolicy: {selection: 'ranked-source-domains', cache: 'validated-single-entry',
          sourceDomains: ['app.notion.com', 'www.notion.com', 'notion.com', 'www.notion.so', 'notion.so'],
          requiredCookies: ['token_v2'], sessionFile: {tokenField: 'tokenV2', cookieName: 'token_v2'}},
        """
        let runtime = try ProviderPluginRuntime(source: """
        defineProvider({id: '\(provider)', name: 'Fixture', settings: [], capabilities: ['browser-cookies'],
        \(declaration) async fetchUsage() {return {empty: true};}});
        """)
        return try #require(runtime.manifest.cookiePolicy)
    }

    private func broker(
        records: [[ProviderPluginCookieRecord]] = [],
        background: Bool = false,
        fileURL: URL? = nil) throws
        -> ProviderPluginCookieBroker
    {
        try ProviderPluginCookieBroker(
            provider: .notion,
            domains: [
                "app.notion.com",
                "www.notion.com",
                "notion.com",
                "www.notion.so",
                "notion.so",
            ],
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            batches: { _, _ in nil },
            jarImporter: { records.map { .init(
                header: "",
                source: "Synthetic profile",
                origin: "",
                records: $0) } },
            policy: self.policy(),
            background: background,
            sessionFileURL: fileURL ?? Self.fileURL)
    }

    private static func record(_ name: String, _ value: String, _ domain: String) throws -> ProviderPluginCookieRecord {
        let cookie = try #require(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]))
        return ProviderPluginCookieRecord(cookie: cookie)
    }

    private func header(_ session: ProviderPluginCookieSession) throws -> String {
        try ProviderPluginCookieJar.header(
            for: session,
            url: #require(URL(string: "https://\(self.domain)/api/v3/getSpaces")))
    }

    private static func write(_ token: String, to url: URL) throws {
        try CredentialFileWriter.writePrivate(
            Data("{\"tokenV2\":\"\(token)\",\"sourceLabel\":\"Fixture\"}".utf8),
            to: url)
    }

    private static func token(_ url: URL) throws -> String? {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))["tokenV2"]
    }

    private func isolated(_ body: (URL) throws -> Void) rethrows {
        try KeychainCacheStore.withImplicitTestStoreForTesting {
            try KeychainCacheStore.withServiceOverrideForTesting("persistent-plugin-\(UUID().uuidString)") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(directory) {
                    try Self.$fileURL.withValue(directory.appendingPathComponent("notion-session.json")) {
                        try body(directory.appendingPathComponent("notion-session.json"))
                    }
                }
            }
        }
    }
}
