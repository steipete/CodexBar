import Foundation
import SQLite3
import Testing
@testable import CodexBarCore
@testable import SweetCookieKit

struct HelmcodePluginTests {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Cloud imports an API host session without a parent domain cookie`(
        engine: ProviderPluginEngineKind) async throws
    {
        let domains = try await Self.browserFixture(engine: engine, domain: "cloud-api.helmcode.com")
        #expect(domains == ["cloud-api.helmcode.com"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Cloud retains parent domain browser sessions without a cache`(
        engine: ProviderPluginEngineKind) async throws
    {
        let domains = try await Self.browserFixture(engine: engine, domain: ".helmcode.com")
        #expect(domains.contains("helmcode.com"))
        #expect(!domains.contains("nan.builders"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a denied Cloud import still permits a usable NaN session`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(engine: engine, denied: ["cloud-api.helmcode.com"])
        #expect(result.usage.identity?.accountOrganization == "NaN Builders")
        #expect(result.domains == ["cloud-api.helmcode.com", "helmcode.com", "nan.builders"])
        #expect(result.requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Cloud golden preserves model resets and prepaid balance`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(engine: engine)
        let usage = result.usage
        #expect(usage.primary?.usedPercent == Double(73_854_494) / 2_000_000_000 * 100)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(usage.extraRateWindows?.map(\.title) == ["helm-monthly-b", "helm-monthly-c", "helm-monthly-d"])
        #expect(usage.providerCost?.used == 12.5)
        #expect(usage.providerCost?.currencyCode == "EUR")
        #expect(usage.providerCost?.period == "Prepaid balance")
        #expect(usage.identity?.providerID == .helmcode)
        #expect(usage.identity?.accountOrganization == "Helmcode Cloud")
        #expect(usage.dataConfidence == .exact)
        #expect(result.requests.count == 3)
        #expect(result.domains == ["cloud-api.helmcode.com"])
        #expect(HelmcodeProviderDescriptor.dashboardURL(snapshot: usage).absoluteString
            == "https://cloud.helmcode.com/dashboard")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `NaN session stays on NaN and never requests prepaid balance`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(engine: engine, available: ["nan.builders"])
        #expect(result.requests.count == 2)
        #expect(result.requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
        #expect(result.usage.providerCost == nil)
        #expect(result.usage.identity?.accountOrganization == "NaN Builders")
        #expect(HelmcodeProviderDescriptor.dashboardURL(snapshot: result.usage).absoluteString
            == "https://cloud.nan.builders/dashboard")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `explicit premium billing reveals rolling windows`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(engine: engine, billing: Self.fixture("billing-premium"))
        let window = try #require(result.usage.extraRateWindows?.first { $0.title == "helm-rolling-a" }?.window)
        #expect(window.windowMinutes == 240)
        #expect(window.resetsAt == ISO8601DateFormatter().date(from: "2026-10-04T19:25:48Z"))
        #expect(result.usage.extraRateWindows?.count == 5)
        #expect(result.usage.primary?.windowMinutes == nil)
    }

    @Test(arguments: ["{}", "not json", #"{"subscription":{"premium":"true"}}"#], BundledPluginTestSupport.engines)
    func `missing malformed and nonboolean premium billing hides rolling tiers`(
        billing: String, engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine, billing: billing)
        #expect(result.usage.extraRateWindows?.count == 3)
        #expect(result.usage.extraRateWindows?.allSatisfy { $0.window.windowMinutes == nil } == true)
    }

    @Test(arguments: [302, 401, 403], BundledPluginTestSupport.engines)
    func `rejected Cloud session is evicted before trying NaN`(
        status: Int,
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine, cloudStatus: status)
        #expect(result.rejected == ["cloud-api.helmcode.com"])
        #expect(result.domains == ["cloud-api.helmcode.com", "helmcode.com", "nan.builders"])
        #expect(result.usage.identity?.accountOrganization == "NaN Builders")
        #expect(result.requests.count == 3)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual cookie uses only its selected tenant`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(engine: engine, source: .manual, tenant: "nanBuilders")
        #expect(result.domains == ["nan.builders"])
        #expect(result.requests.count == 2)
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(engine: engine, source: .manual, cloudStatus: 401).usage
        }
    }

    @Test(arguments: [ProviderCookieSource.off, .auto], BundledPluginTestSupport.engines)
    func `Off and missing sessions fail without HTTP`(
        source: ProviderCookieSource,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.missingCredential) {
            try await Self.fetch(engine: engine, source: source, available: []).usage
        }
    }

    @Test(arguments: [429, 500], BundledPluginTestSupport.engines)
    func `transient Cloud errors do not switch tenants`(status: Int, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(status == 429 ? .rateLimited : .providerUnavailable) {
            try await Self.fetch(engine: engine, cloudStatus: status).usage
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `quota schema drift is classified and optional failures preserve quota`(
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(engine: engine, quota: Self.fixture("quota-drifted")).usage
        }
        do {
            let result = try await Self.fetch(engine: engine, billing: "bad JSON", optionalStatus: 503)
            #expect(result.usage.primary != nil)
            #expect(result.usage.providerCost == nil)
            #expect(result.usage.extraRateWindows?.count == 3)
        } catch { Issue.record(error) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `monthly fallback credit tokens and zero caps project honestly`(
        engine: ProviderPluginEngineKind) async throws
    {
        let quota = #"""
        {"periodStart":"2026-12-15","models":[
          {"model":"helm-unlimited","cap":0,"tokensUsed":100},
          {"model":"helm-a","cap":1000,"tokensUsed":2000,"creditTokens":20}]}
        """#
        let usage = try await Self.fetch(engine: engine, quota: quota).usage
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetsAt ==
            ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        #expect(usage.primary?.resetDescription?.contains("20 credit-funded") == true)
        #expect(usage.extraRateWindows?.isEmpty != false)
    }

    @Test(
        arguments: [#"{"balanceMicros":12500000,"currency":12}"#, #"{"balanceMicros":"12500000"}"#],
        BundledPluginTestSupport.engines)
    func `malformed optional credit fields do not invent a currency or balance`(
        credits: String, engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine, credits: credits)
        #expect(result.usage.primary != nil)
        #expect(result.usage.providerCost == nil)
    }

    @Test
    func `descriptor uses the plugin and preserves cookie configuration`() {
        let descriptor = HelmcodeProviderDescriptor.descriptor
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(HelmcodeProviderSettings(
            cookieSource: .manual, manualCookieHeader: "fixture", manualTenant: "nanBuilders")
            .manualTenant == "nanBuilders")
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Providers/Helmcode"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func browserFixture(engine: ProviderPluginEngineKind, domain: String) async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('version', '24');
        CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER,
          is_secure INTEGER, is_httponly INTEGER, value TEXT, encrypted_value BLOB);
        INSERT INTO cookies VALUES
          ('\(domain)', 'session', '/', 0, 1, 1, 'fixture-cloud-session', X'');
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = BrowserCookieStore(
            browser: .chrome,
            profile: .init(id: "fixture", name: "Fixture"),
            kind: .network,
            label: "Synthetic",
            databaseURL: database)
        let cookieHeader: @Sendable (String) throws -> String = { domain in
            let query = ProviderPluginCookieBroker.cookieQuery(domain: domain)
            let cookies = try ChromeCookieImporter.loadCookies(
                from: store,
                matchingDomains: query.domains,
                domainMatch: query.domainMatch,
                safeStorageKey: { _ in
                    Issue.record("Plaintext fixture must not request Safe Storage")
                    return Data()
                })
            guard !cookies.isEmpty else { throw ProviderPluginError.secretAccess("No matching fixture cookie") }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        // Validate the SQLite fixture before the plugin can classify an import error as a missing session.
        let fixtureHeader = try cookieHeader(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        try #require(fixtureHeader == "session=fixture-cloud-session")
        let result = try await Self.fetch(engine: engine, cookieResolver: cookieHeader)
        #expect(result.usage.identity?.accountOrganization == "Helmcode Cloud")
        #expect(result.requests.count == 3)
        #expect(result.requests.allSatisfy { $0.url?.host == "cloud-api.helmcode.com" })
        #expect(result.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "session=fixture-cloud-session"
        })
        return result.domains
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        source: ProviderCookieSource = .auto,
        tenant: String = "helmcode",
        available: Set<String> = ["cloud-api.helmcode.com", "nan.builders"],
        denied: Set<String> = [],
        cloudStatus: Int = 200,
        quota: String? = nil,
        billing: String? = nil,
        credits: String? = nil,
        optionalStatus: Int = 200,
        cookieResolver: (@Sendable (String) throws -> String)? = nil) async throws
        -> (usage: UsageSnapshot, requests: [URLRequest], domains: [String], rejected: [String])
    {
        let quotaBody = try quota ?? Self.fixture("quota")
        let billingBody = try billing ?? Self.fixture("billing")
        let creditsBody = try credits ?? Self.fixture("credits")
        let domains = Recorder()
        let rejected = Recorder()
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let domain = url.host == "cloud-api.helmcode.com" ? "helmcode.com" : "nan.builders"
            let cookieDomain = domain == "helmcode.com" ? "cloud-api.helmcode.com" : domain
            if cookieResolver == nil {
                #expect(request.value(forHTTPHeaderField: "Cookie") == "__Host-session=\(cookieDomain)")
            }
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.\(domain)")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.\(domain)/dashboard")
            #expect(request.timeoutInterval == (url.path == "/api/usage/quota" ? 8 : 2))
            var code = optionalStatus
            let body: String
            switch url.path {
            case "/api/usage/quota":
                code = domain == "helmcode.com" ? cloudStatus : 200
                body = quotaBody
            case "/api/billing": body = billingBody
            case "/api/billing/credits":
                #expect(domain == "helmcode.com")
                body = creditsBody
            default: throw URLError(.badURL)
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
        let runtime = try BundledPluginTestSupport.runtime("helmcode", engine: engine, transport: transport)
        let usage = try await runtime.fetchUsage(
            settings: ["TENANT": tenant],
            now: Self.now,
            cookieSource: source,
            cookieInvalidator: { rejected.append($0) },
            cookieResolver: { provider, domain in
                #expect(provider == .helmcode)
                domains.append(domain)
                if let cookieResolver { return try cookieResolver(domain) }
                if denied
                    .contains(domain) { throw ProviderPluginError.secretAccess("Synthetic cookie permission denial") }
                guard available.contains(domain) else { throw ProviderPluginError.secretAccess("missing fixture") }
                return "__Host-session=\(domain)"
            })
        return await (usage, transport.requests(), domains.values, rejected.values)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind, operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch { Issue.record(error) }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var values: [String] {
            self.lock.withLock { self.recorded }
        }

        func append(_ value: String) { self.lock.withLock { self.recorded.append(value) } }
    }
}
