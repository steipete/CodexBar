import Foundation
import os.lock
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderBrowserSessionTests {
    @Test(arguments: [
        ProviderFetchClassifiedError.Kind.authenticationExpired, .permissionDenied, .parseFailure, .apiFailure,
    ])
    func `classified failures cannot retain or suppress usage through misleading error text`(
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        let prior = try await LangdockPluginTests.fetch(LangdockPluginTests.body(LangdockPluginTests.plan))
        let error = ProviderBrowserSessionFailure(
            owner: prior.browserSessionOwner,
            underlyingError: ProviderFetchClassifiedError(kind: kind, message: "Session cancelled after a timeout"))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true, priorSnapshot: prior))
        #expect(!UsageStore.shouldSuppressProviderCancellation(error, priorSnapshot: prior))
        let timeout = ProviderBrowserSessionFailure(
            owner: prior.browserSessionOwner,
            underlyingError: ProviderPluginError.timedOut)
        #expect(UsageStore.shouldPreservePriorSnapshot(after: timeout, hadPriorData: true, priorSnapshot: prior))
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["success", "http", "network", "cancelled"])
    func `same profile login changes discard success errors and cancellation`(
        engine: ProviderPluginEngineKind, outcome: String) async throws
    {
        for selectedProfile in LangdockPluginTests.profiles {
            let token = OSAllocatedUnfairLock(initialState: "synthetic-account-a")
            let interactions = OSAllocatedUnfairLock(initialState: [ProviderInteraction]())
            let runtime = try Self.runtime(engine, outcome: outcome) { token.withLock { $0 = "synthetic-account-b" } }
            let failure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    let broker = LangdockPluginTests.broker(runtime, profile: selectedProfile) { profile in
                        #expect(profile == selectedProfile)
                        interactions.withLock { $0.append(ProviderInteractionContext.current) }
                        return try [LangdockPluginTests.record(token.withLock { $0 })]
                    }
                    return try await runtime.fetchResult(cookies: broker)
                }
            })
            #expect(failure.owner == nil)
            #expect((failure.underlyingError as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
            #expect(interactions.withLock { $0 } == [.userInitiated, .background])
            let prior = try await LangdockPluginTests.fetch(
                LangdockPluginTests.body(LangdockPluginTests.plan),
                profile: selectedProfile,
                engine: engine)
            #expect(!UsageStore.shouldPreservePriorSnapshot(after: failure, hadPriorData: true, priorSnapshot: prior))
            #expect(!UsageStore.shouldSuppressProviderCancellation(failure, priorSnapshot: prior))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["http", "network", "cancelled"])
    func `only revalidated ownership can retain prior measurements after transient errors`(
        engine: ProviderPluginEngineKind, outcome: String) async throws
    {
        let runtime = try Self.runtime(engine, outcome: outcome)
        let prior = try await LangdockPluginTests.fetch(
            LangdockPluginTests.body(LangdockPluginTests.plan),
            engine: engine)
        let failure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
            try await runtime.fetchResult(cookies: LangdockPluginTests.broker(runtime))
        })
        #expect(failure.owner == prior.browserSessionOwner)
        #expect(UsageStore.shouldPreservePriorSnapshot(after: failure, hadPriorData: true, priorSnapshot: prior))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(prior))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: failure, hadPriorData: true, priorSnapshot: decoded))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: URLError(.timedOut),
            hadPriorData: true,
            priorSnapshot: prior))
    }

    @Test(arguments: BundledPluginTestSupport.engines, [false, true])
    func `failed import or revalidation cannot publish or retain an unverified session`(
        engine: ProviderPluginEngineKind, failRevalidation: Bool) async throws
    {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let runtime = try Self.runtime(engine)
        let broker = LangdockPluginTests.broker(runtime) { _ in
            let count = reads.withLock { $0 += 1; return $0 }
            if failRevalidation, count == 1 { return try [LangdockPluginTests.record()] }
            throw ProviderFetchClassifiedError(kind: .permissionDenied, message: "Synthetic profile unreadable")
        }
        let failure = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
            try await runtime.fetchResult(cookies: broker)
        })
        #expect(failure.owner == nil)
        #expect((failure.underlyingError as? ProviderFetchClassifiedError)?.kind == .permissionDenied)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `selected sessions never expose credentials and never consult another profile or cache`(
        engine: ProviderPluginEngineKind) async throws
    {
        for selectedProfile in LangdockPluginTests.profiles {
            let source = ProviderPluginSelectedProfileTests.source.replacingOccurrences(
                of: "const response = await", with: """
                if (session.header !== undefined || session.cacheKey !== undefined || session.fingerprint !== undefined)
                  throw new Error('Session secret exposed');
                let denied = false;
                try { await ctx.browser.cookieHeader('app.langdock.com'); } catch { denied = true; }
                if (!denied) throw new Error('Header API exposed');
                const response = await
                """)
            let runtime = try Self.runtime(engine, source: source)
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: storage) }
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                CookieHeaderCache.store(
                    provider: .langdock,
                    cookieHeader: "auth_token=other-account",
                    sourceLabel: "Other")
                let broker = LangdockPluginTests.broker(runtime, profile: selectedProfile)
                #expect(try broker.nextSession(domain: "app.langdock.com", cachedOnly: true) == nil)
                let result = try await runtime.fetchResult(cookies: broker)
                #expect(result.usage.primary?.usedPercent == 42)
                #expect(try broker.nextSession(domain: "app.langdock.com") == nil)
                #expect(CookieHeaderCache.load(provider: .langdock)?.cookieHeader == "auth_token=other-account")
            }
        }
    }

    @Test
    func `ownership tracks auth identity rather than preferences and excludes unrelated paths`() throws {
        let runtime = try ProviderPluginRuntime(bundledPlugin: "langdock")
        let policy = try #require(runtime.manifest.cookiePolicy)
        let record = try LangdockPluginTests.record()
        func owner(
            _ records: [ProviderPluginCookieRecord],
            profile: ProviderBrowserProfile = LangdockPluginTests.profile)
            throws -> ProviderBrowserSessionOwner
        {
            try ProviderBrowserSessionOwner(provider: .langdock, profile: profile, records: records, policy: policy)
        }
        let expected = try owner([record])
        #expect(try expected == owner([record, LangdockPluginTests.record("changed", name: "preference")]))
        #expect(try expected == owner([record, LangdockPluginTests.record("unrelated", path: "/settings")]))
        #expect(try expected != owner([LangdockPluginTests.record("other-login")]))
        #expect(try expected != owner(
            [record],
            profile: .init(browserID: "edge", profileID: "/synthetic/Edge/Profile 1")))
        #expect(try expected != owner(
            [record],
            profile: .init(browserID: "chrome", profileID: LangdockPluginTests.profile.profileID)))
        #expect(throws: ProviderFetchClassifiedError.self) { try owner([]) }
        #expect(throws: ProviderFetchClassifiedError.self) { try owner([
            record,
            LangdockPluginTests.record("conflicting"),
        ]) }
    }

    @Test(arguments: [Browser.edge, .chrome, .safari])
    func `only the explicitly configured store is read even when another is first`(browser: Browser) throws {
        func store(
            _ id: String,
            browser: Browser = .edge,
            kind: BrowserCookieStoreKind = .network) -> BrowserCookieStore
        {
            BrowserCookieStore(
                browser: browser,
                profile: .init(id: id, name: "Fixture"),
                kind: kind,
                label: "Fixture",
                databaseURL: URL(fileURLWithPath: id).appendingPathComponent("Cookies"))
        }
        let directory = "/synthetic/selected"
        let expected = store(directory, browser: browser, kind: browser == .safari ? .safari : .network)
        let selected = try ProviderBrowserProfile(
            browserID: browser.rawValue,
            profileID: #require(ProviderBrowserProfile.selectableProfile(for: expected)).id)
        let stores = [
            store("/synthetic/other", browser: browser, kind: browser == .safari ? .safari : .network),
            store(directory, browser: browser == .chrome ? .edge : .chrome),
            expected,
            store(directory, browser: browser, kind: browser == .safari ? .safari : .primary),
        ]
        #expect(try ProviderBrowserProfile.selectedStore(selected, from: stores) == expected)
        #expect(throws: ProviderFetchClassifiedError.self) {
            try ProviderBrowserProfile.selectedStore(
                .init(browserID: browser.rawValue, profileID: "/synthetic/absent"),
                from: stores)
        }
    }

    @Test
    func `live copies preserve ownership while serialization strips it`() async throws {
        let snapshot = try await LangdockPluginTests.fetch(LangdockPluginTests.body(LangdockPluginTests.plan))
        let owner = try #require(snapshot.browserSessionOwner)
        for copy in [
            snapshot.with(details: []),
            snapshot.withIdentity(snapshot.identity),
            snapshot.scoped(to: .langdock),
        ] {
            #expect(copy.browserSessionOwner == owner)
        }
        let data = try JSONEncoder().encode(snapshot)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(owner.digest))
        #expect(!text.contains("synthetic-account-a"))
        #expect(!text.contains("browserSessionOwner"))
        #expect(!String(reflecting: snapshot).contains(owner.digest))
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data).browserSessionOwner == nil)
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        outcome: String = "success",
        source: String = ProviderPluginSelectedProfileTests.source,
        afterRequest: @escaping @Sendable () -> Void = {}) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: source,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-account-a")
                afterRequest()
                if outcome == "network" { throw URLError(.timedOut) }
                if outcome == "cancelled" { throw URLError(.cancelled) }
                let url = try #require(request.url)
                return try (Data(#"{"percent":42}"#.utf8), #require(HTTPURLResponse(
                    url: url,
                    statusCode: outcome == "http" ? 503 : 200,
                    httpVersion: nil,
                    headerFields: nil)))
            },
            engine: engine)
    }
}
