import Foundation
import Testing
@testable import CodexBarCore

struct UserPluginCookieTraversalTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `user plugin skips empty browsers and rejects stale sessions before using Aside`(
        engine: ProviderPluginEngineKind) async throws
    {
        let imports = Imports()
        let runtime = try ProviderPluginRuntime(source: Self.source("""
        for await (const session of ctx.browser.sessions("example.test")) {
          if (session.header === "session=expired") {
            ctx.browser.rejectCookie("example.test", session);
            continue;
          }
          return { identity: { loginMethod: session.source } };
        }
        throw new Error("missing fixture session");
        """), engine: engine)
        let cookies = UserProviderPluginCookieBroker.resolvers(batches: imports.load)
        let snapshot = try await runtime.fetchUsage(
            cookieInvalidator: cookies.invalidate,
            cookieSessionResolver: cookies.session,
            cookieSessionInvalidator: cookies.invalidateSession,
            instanceCookieResolver: cookies.header)
        #expect(snapshot.identity?.loginMethod == "Aside")
        #expect(imports.calls == [0, 1, 2])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `first available user plugin header leaves later browsers unread`(
        engine: ProviderPluginEngineKind) async throws
    {
        let imports = Imports()
        let cookies = UserProviderPluginCookieBroker.resolvers(batches: imports.load)
        #expect(try await cookies.session("example.test", true) == nil)
        #expect(imports.calls.isEmpty)
        let runtime = try ProviderPluginRuntime(source: Self.source("""
        const header = await ctx.browser.cookieHeader("example.test");
        const same = header === await ctx.browser.cookieHeader("example.test");
        return { identity: { loginMethod: same ? "first" : "wrong" } };
        """), engine: engine)
        let snapshot = try await runtime.fetchUsage(
            cookieInvalidator: cookies.invalidate,
            cookieSessionResolver: cookies.session,
            cookieSessionInvalidator: cookies.invalidateSession,
            instanceCookieResolver: cookies.header)
        #expect(snapshot.identity?.loginMethod == "first")
        #expect(imports.calls == [0, 1])
    }

    @Test
    func `reused header only resolvers import fresh cookies on every call`() async throws {
        let imports = Imports()
        let resolver = UserProviderPluginCookieBroker.resolver(batches: imports.load)
        _ = try await resolver(.synthetic, "example.test")
        _ = try await resolver(.synthetic, "example.test")
        #expect(imports.calls == [0, 1, 0, 1])
    }

    @Test
    func `late rejection cannot clear a newer browser session`() async throws {
        let imports = Imports()
        let cookies = UserProviderPluginCookieBroker.resolvers(batches: imports.load)
        let first = try #require(await cookies.session("example.test", false))
        let second = try #require(await cookies.session("example.test", false))
        cookies.invalidateSession("example.test", first.id)
        #expect(try await cookies.header(.synthetic, "example.test") == second.header)
        #expect(imports.calls == [0, 1, 2])
    }

    @Test(arguments: ["undeclared.test", "example.test"], BundledPluginTestSupport.engines)
    func `undeclared domains and API only mode never reach browser imports`(
        domain: String, engine: ProviderPluginEngineKind) async throws
    {
        let imports = Imports()
        let runtime = try ProviderPluginRuntime(source: Self.source("""
        await ctx.browser.cookieHeader("\(domain)");
        return { primary: { usedPercent: 1 } };
        """), engine: engine)
        let cookies = UserProviderPluginCookieBroker.resolvers(batches: imports.load)
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(
                sourceMode: domain == "example.test" ? .api : .auto,
                cookieInvalidator: cookies.invalidate,
                cookieSessionResolver: cookies.session,
                cookieSessionInvalidator: cookies.invalidateSession,
                instanceCookieResolver: cookies.header)
        }
        #expect(imports.calls.isEmpty)
    }

    @Test
    func `manual user plugin sessions do not discover browser profiles`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("manual.js")
        let source = Self.source("""
        for await (const session of ctx.browser.sessions("example.test")) {
          return { identity: { loginMethod: session.header === "session=manual" ? "manual" : "wrong" } };
        }
        throw new Error("missing manual session");
        """).replacingOccurrences(of: "id: \"synthetic\"", with: "id: \"manual-cookie-fixture\"")
        try Data(source.utf8).write(to: url)
        let plugin = try UserProviderPluginLoader(
            providersDirectory: root, cacheDirectory: root.appendingPathComponent("cache")).load(fileURL: url)
        let approvals = ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        try approvals.record(plugin.approvalBinding(settings: [:]))
        let detection = BrowserDetection(
            homeDirectory: root.path,
            cacheTTL: 0,
            now: { Date(timeIntervalSince1970: 0) },
            fileExists: { _ in
                Issue.record("Manual sessions must not inspect browser profiles")
                return false
            },
            directoryContents: { _ in [] },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        let snapshot = try await plugin.fetchUsage(
            settings: [:],
            secrets: [:],
            environment: [:],
            approvalStore: approvals,
            cookieSource: .manual,
            instanceCookieResolver: { _, _ in "session=manual" },
            browserDetection: detection)
        #expect(snapshot.identity?.loginMethod == "manual")
    }

    private static func source(_ body: String) -> String {
        """
        defineProvider({
          id: "synthetic", name: "Fixture", endpoints: ["https://example.test"], settings: [],
          capabilities: ["browser-cookies"], cookieDomains: ["example.test"],
          async fetchUsage(ctx) { \(body) }
        });
        """
    }

    private final class Imports: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [Int] = []
        var calls: [Int] {
            self.lock.withLock { self.requested }
        }

        func load(_: String, batch: Int) -> [(header: String, source: String)]? {
            self.lock.withLock {
                self.requested.append(batch)
                switch batch {
                case 0: return []
                case 1: return [("session=expired", "Chrome")]
                case 2: return [("session=valid", "Aside")]
                default:
                    Issue.record("Read a later browser after a usable session")
                    return nil
                }
            }
        }
    }
}
