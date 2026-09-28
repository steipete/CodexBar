import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginPersistentCookieSecurityTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `declared access gate preserves CLI refresh and prompt free import attempts`(
        engine: ProviderPluginEngineKind) throws
    {
        let gated = try #require(Self.runtime(
            engine,
            policy: "{selection: 'request-url', cache: 'validated-single-entry', imports: 'access-gated'}",
            body: "return {empty: true};").manifest.cookiePolicy)
        #expect(gated.allowsImportAttempt(runtime: .cli, interaction: .userInitiated))
        #expect(gated.allowsImportAttempt(runtime: .cli, interaction: .background))
        #expect(gated.allowsImportAttempt(runtime: .app, interaction: .background))
        let restricted = try #require(Self.runtime(engine, body: "return {empty: true};").manifest.cookiePolicy)
        #expect(restricted.allowsImportAttempt(runtime: .app, interaction: .userInitiated))
        #expect(!restricted.allowsImportAttempt(runtime: .cli, interaction: .userInitiated))
        #expect(!restricted.allowsImportAttempt(runtime: .app, interaction: .background))
        #if os(macOS)
        let checks: [(KeychainAccessPreflight.Outcome, Bool)] = [
            (.allowed, true), (.interactionRequired, false), (.notFound, false), (.failure(-25293), false),
        ]
        for (outcome, allowed) in checks {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                ProviderInteractionContext.$current.withValue(.background) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in outcome } operation: {
                        #expect(BrowserCookieAccessGate.shouldAttempt(.chrome) == allowed)
                    }
                }
            }
        }
        #endif
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cookie policy rejects malformed or undeclared authority`(engine: ProviderPluginEngineKind) {
        for policy in [
            "null", "[]", "{selection: 'unknown', cache: 'validated-single-entry'}",
            "{selection: 'request-url', cache: 'forever'}",
            "{selection: 'request-url', cache: 'validated-single-entry', imports: 'always-prompt'}",
            "{selection: 'ranked-source-domains', cache: 'validated-single-entry', sourceDomains: ['evil.test']}",
            "{selection: 'ranked-source-domains', cache: 'validated-single-entry', sourceDomains: ['example.test', 'example.test']}",
            "{selection: 'request-url', cache: 'validated-single-entry', requiredCookies: ['bad\\nname']}",
            "{selection: 'request-url', cache: 'validated-single-entry', missingCookies: true}",
            "{selection: 'request-url', cache: 'validated-single-entry', sessionFile: {path: '/tmp/arbitrary'}}",
            "{selection: 'request-url', cache: 'nonpersistent', sessionFile: {tokenField: 'token', cookieName: 'session'}}",
        ] {
            #expect(throws: ProviderPluginError.self) {
                try Self.runtime(engine, policy: policy, body: "return {empty: true};")
            }
        }
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginRuntime(source: """
            defineProvider({id: 'user-fixture', name: 'Fixture', settings: [], endpoints: ['https://example.test'],
              capabilities: ['browser-cookies'], cookieDomains: ['example.test'],
              cookiePolicy: {selection: 'request-url', cache: 'validated-single-entry'}, fetchUsage() {return {empty: true};}});
            """, allowsDynamicID: true, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `forged rejected and wrong-origin sessions cannot be accepted`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            "ctx.browser.acceptCookie('example.test', {id: 'forged'});",
            "for await (const session of ctx.browser.sessions('example.test')) { ctx.browser.rejectCookie('example.test', session); ctx.browser.acceptCookie('example.test', session); break; }",
            "for await (const session of ctx.browser.sessions('example.test')) { ctx.browser.acceptCookie('other.test', session); break; }",
        ] {
            let runtime = try Self.runtime(engine, body: body + "return {empty: true};")
            await #expect(throws: (any Error).self) {
                try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
                    .init(header: "session=fixture", source: "Fixture", origin: "https://example.test")
                }, cookieSessionValidator: { _, _ in Issue.record("Invalid IDs must not reach persistence") })
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `legacy host map cookies stay opaque and are redacted from errors`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine, body: """
        for await (const session of ctx.browser.sessions('example.test')) {
          if (session.header !== undefined || session.headersByHost !== undefined || session.records !== undefined)
            throw new Error('cookie escaped');
          throw new Error('synthetic-private-cookie');
        }
        """)
        do {
            _ = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
                .init(
                    header: "",
                    source: "Fixture",
                    origin: "https://example.test",
                    headersByHost: ["example.test": "session=synthetic-private-cookie"])
            })
            Issue.record("Expected an error")
        } catch {
            #expect(!error.localizedDescription.contains("synthetic-private-cookie"))
            #expect(!error.localizedDescription.contains("cookie escaped"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `snapshot overage policy is typed and still rejects nonfinite values`(
        engine: ProviderPluginEngineKind) async throws
    {
        for policy in [
            "null",
            "{percent: true}",
            "{percent: 'unbounded'}",
            "{percent: 'preserve-overage', extra: true}",
        ] {
            #expect(throws: ProviderPluginError.self) {
                try ProviderPluginRuntime(source: """
                defineProvider({id: 'notion', name: 'Fixture', settings: [], endpoints: ['https://example.test'],
                  snapshotPolicy: \(policy), fetchUsage() {return {empty:true};}});
                """, engine: engine)
            }
        }
        for number in ["NaN", "Infinity", "'120'"] {
            let runtime = try ProviderPluginRuntime(source: """
            defineProvider({id: 'notion', name: 'Fixture', settings: [], endpoints: ['https://example.test'],
              snapshotPolicy: {percent: 'preserve-overage'}, fetchUsage() {return {primary:{usedPercent:\(number)}};}});
            """, engine: engine)
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        policy: String = "{selection: 'request-url', cache: 'validated-single-entry'}",
        body: String) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(source: """
        defineProvider({id: 'notion', name: 'Fixture', settings: [], endpoints: ['https://example.test'],
          capabilities: ['browser-cookies'], cookieDomains: ['example.test', 'other.test'],
          cookiePolicy: \(policy), async fetchUsage(ctx) {\(body)}});
        """, engine: engine)
    }
}
