import Foundation
import Testing
@testable import CodexBarCore

struct HelmcodeCookieCompatibilityTests {
    @TaskLocal private static var cacheContext: CacheContext?

    @Test(arguments: BundledPluginTestSupport.engines)
    func `previous Cloud cache remains usable without browser access`(engine: ProviderPluginEngineKind) async throws {
        try await Self.isolated {
            let cloud = try Self.store(domain: "helmcode.com", header: "session=previous-cloud")
            let nan = try Self.store(domain: "nan.builders", header: "session=nan")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports)

            let result = try await Self.fetch(engine: engine, broker: broker)

            #expect(result.usage.identity?.accountOrganization == "Helmcode Cloud")
            #expect(result.requests.count == 3)
            #expect(result.requests.allSatisfy { $0.url?.host == "cloud-api.helmcode.com" })
            #expect(result.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == cloud.cookieHeader })
            #expect(imports.value.isEmpty)
            #expect(Self.cached("helmcode.com")?.cookieHeader == cloud.cookieHeader)
            #expect(Self.cached("helmcode.com")?.storedAt == cloud.storedAt)
            #expect(Self.cached("nan.builders")?.cookieHeader == nan.cookieHeader)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected previous Cloud cache leaves API host and NaN sessions intact`(
        engine: ProviderPluginEngineKind) async throws
    {
        try await Self.isolated {
            _ = try Self.store(domain: "helmcode.com", header: "session=rejected-cloud")
            let cloud = try Self.store(domain: "cloud-api.helmcode.com", header: "session=current-cloud")
            let nan = try Self.store(domain: "nan.builders", header: "session=nan")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports)

            let result = try await Self.fetch(engine: engine, broker: broker, quotaStatus: { request in
                request.value(forHTTPHeaderField: "Cookie") == "session=rejected-cloud" ? 401 : 200
            })

            #expect(result.usage.identity?.accountOrganization == "Helmcode Cloud")
            #expect(result.requests.count == 4)
            #expect(result.requests.last?.value(forHTTPHeaderField: "Cookie") == cloud.cookieHeader)
            #expect(imports.value.isEmpty)
            #expect(Self.cached("helmcode.com") == nil)
            #expect(Self.cached("cloud-api.helmcode.com")?.cookieHeader == cloud.cookieHeader)
            #expect(Self.cached("nan.builders")?.cookieHeader == nan.cookieHeader)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `late rejection cannot remove a newer previous scope session`(engine: ProviderPluginEngineKind) async throws {
        try await Self.isolated {
            _ = try Self.store(domain: "helmcode.com", header: "session=old-cloud")
            _ = try Self.store(domain: "cloud-api.helmcode.com", header: "session=current-cloud")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports)

            let result = try await Self.fetch(engine: engine, broker: broker, quotaStatus: { request in
                guard request.value(forHTTPHeaderField: "Cookie") == "session=old-cloud" else { return 200 }
                CookieHeaderCache.store(
                    provider: .helmcode,
                    scope: .providerVariant("helmcode.com"),
                    cookieHeader: "session=newer-cloud",
                    sourceLabel: "Synthetic newer session")
                return 401
            })

            #expect(result.usage.identity?.accountOrganization == "Helmcode Cloud")
            #expect(Self.cached("helmcode.com")?.cookieHeader == "session=newer-cloud")
            #expect(Self.cached("cloud-api.helmcode.com")?.cookieHeader == "session=current-cloud")
            #expect(imports.value.isEmpty)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `NaN cache remains usable when Cloud browser access is unavailable`(
        engine: ProviderPluginEngineKind) async throws
    {
        try await Self.isolated {
            let nan = try Self.store(domain: "nan.builders", header: "session=nan")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports)

            let result = try await Self.fetch(engine: engine, broker: broker)

            #expect(result.usage.identity?.accountOrganization == "NaN Builders")
            #expect(result.requests.count == 2)
            #expect(result.requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
            #expect(result.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nan.cookieHeader })
            #expect(imports.value == ["cloud-api.helmcode.com", "helmcode.com"])
            #expect(Self.cached("nan.builders")?.cookieHeader == nan.cookieHeader)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `API host cache remains usable without a previous Cloud entry`(engine: ProviderPluginEngineKind) async throws {
        try await Self.isolated {
            let cloud = try Self.store(domain: "cloud-api.helmcode.com", header: "session=current-cloud")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports)

            let result = try await Self.fetch(engine: engine, broker: broker)

            #expect(result.usage.identity?.accountOrganization == "Helmcode Cloud")
            #expect(result.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == cloud.cookieHeader })
            #expect(imports.value.isEmpty)
            #expect(Self.cached("cloud-api.helmcode.com")?.cookieHeader == cloud.cookieHeader)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["helmcode", "nanBuilders"])
    func `manual tenant selection does not consume or change existing caches`(
        engine: ProviderPluginEngineKind,
        tenant: String) async throws
    {
        try await Self.isolated {
            let cloud = try Self.store(domain: "helmcode.com", header: "session=previous-cloud")
            let nan = try Self.store(domain: "nan.builders", header: "session=nan")
            let imports = LockIsolated<[String]>([])
            let broker = Self.broker(imports: imports, source: .manual)

            let result = try await Self.fetch(engine: engine, broker: broker, source: .manual, tenant: tenant)

            let host = tenant == "helmcode" ? "cloud-api.helmcode.com" : "cloud-api.nan.builders"
            #expect(result.requests.allSatisfy { $0.url?.host == host })
            #expect(result.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "session=manual" })
            #expect(imports.value.isEmpty)
            #expect(Self.cached("helmcode.com")?.cookieHeader == cloud.cookieHeader)
            #expect(Self.cached("nan.builders")?.cookieHeader == nan.cookieHeader)
        }
    }

    private static func cached(_ domain: String) -> CookieHeaderCache.Entry? {
        CookieHeaderCache.load(provider: .helmcode, scope: .providerVariant(domain))
    }

    private static func store(domain: String, header: String) throws -> CookieHeaderCache.Entry {
        CookieHeaderCache.store(
            provider: .helmcode,
            scope: .providerVariant(domain),
            cookieHeader: header,
            sourceLabel: "Synthetic cached session",
            now: HelmcodePluginTests.now)
        return try #require(self.cached(domain))
    }

    private static func broker(
        imports: LockIsolated<[String]>,
        source: ProviderCookieSource = .auto) -> ProviderPluginCookieBroker
    {
        ProviderPluginCookieBroker(
            provider: .helmcode,
            domains: ["helmcode.com", "cloud-api.helmcode.com", "nan.builders"],
            settings: .init(cookieSource: source, manualCookieHeader: "session=manual"),
            batches: { domain, _ in
                imports.setValue(imports.value + [domain])
                throw URLError(.userAuthenticationRequired)
            })
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        broker: ProviderPluginCookieBroker,
        source: ProviderCookieSource = .auto,
        tenant: String = "helmcode",
        quotaStatus: @escaping @Sendable (URLRequest) -> Int = { _ in 200 }) async throws
        -> (usage: UsageSnapshot, requests: [URLRequest])
    {
        let context = try #require(Self.cacheContext)
        let quota = try HelmcodePluginTests.fixture("quota")
        let billing = try HelmcodePluginTests.fixture("billing")
        let credits = try HelmcodePluginTests.fixture("credits")
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let domain = url.host == "cloud-api.helmcode.com" ? "helmcode.com" : "nan.builders"
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.\(domain)")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.\(domain)/dashboard")
            let body: String
            let status: Int
            switch url.path {
            case "/api/usage/quota":
                body = quota
                status = context.perform { quotaStatus(request) }
            case "/api/billing":
                body = billing
                status = 200
            case "/api/billing/credits":
                #expect(url.host == "cloud-api.helmcode.com")
                body = credits
                status = 200
            default:
                throw URLError(.badURL)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
        let runtime = try BundledPluginTestSupport.runtime("helmcode", engine: engine, transport: transport)
        let usage = try await runtime.fetchUsage(
            settings: ["TENANT": tenant],
            now: HelmcodePluginTests.now,
            cookieSource: source,
            cookieInvalidator: { domain in
                context.perform { broker.rejectCookie(domain: domain) }
            },
            cookieSessionResolver: { domain, cachedOnly in
                try context.perform { try broker.nextSession(domain: domain, cachedOnly: cachedOnly) }
            },
            cookieSessionInvalidator: { domain, id in
                context.perform { broker.rejectCookie(domain: domain, id: id) }
            },
            cookieResolver: { provider, domain in
                #expect(provider == .helmcode)
                return try context.perform { try broker.cookieHeader(domain: domain) }
            })
        return await (usage, transport.requests())
    }

    private static func isolated(_ operation: () async throws -> Void) async rethrows {
        let context = CacheContext(
            service: "helmcode-compatibility-\(UUID().uuidString)",
            legacyURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: context.legacyURL) }
        try await Self.$cacheContext.withValue(context) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await KeychainCacheStore.withServiceOverrideForTesting(context.service) {
                    try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(
                        context.legacyURL, operation: operation)
                }
            }
        }
    }

    private struct CacheContext: Sendable {
        let service: String
        let legacyURL: URL

        func perform<T>(_ operation: () throws -> T) rethrows -> T {
            try KeychainCacheStore.withImplicitTestStoreForTesting {
                try KeychainCacheStore.withServiceOverrideForTesting(self.service) {
                    try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(self.legacyURL, operation: operation)
                }
            }
        }
    }
}
