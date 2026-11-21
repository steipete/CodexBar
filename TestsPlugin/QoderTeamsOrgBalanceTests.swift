import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CodexBarCore

struct QoderTeamsOrgBalanceTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `Teams empty member exposes the organization balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let invalidations = StringLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.organizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: invalidations)

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "0 / 0 credits")
        #expect(usage.primary?.resetsAt == Self.refreshDate)
        #expect(usage.secondary?.usedPercent == 24)
        #expect(usage.secondary?.remainingPercent == 76)
        #expect(usage.secondary?.resetDescription == "1,200 / 5,000 credits")
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.extraRateWindows == nil)
        #expect(usage.subscriptionRenewsAt == nil)

        let captured = requests.value
        #expect(captured.count == 2)
        #expect(captured.contains { $0.url?.path == "/api/v2/me/usages/big_model_credits" })
        #expect(captured.contains { $0.url?.path == "/sash/api/v2/me/usage" })
        #expect(captured.allSatisfy { $0.url?.host == "qoder.com" })
        #expect(invalidations.value.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Non-empty member skips the supplemental request`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.organizationJSON),
            member: Self.nonzeroMemberJSON,
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "25 / 100 credits")
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 1)
        #expect(!requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `isQuotaExceeded marks the organization balance exhausted without remaining credits`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.exhaustedOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.secondary?.remainingPercent == 0)
        #expect(usage.secondary?.resetDescription == "5,000 / 5,000 credits")
        #expect(requests.value.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `A positive balance wins over used capacity`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.positiveBalanceOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.secondary?.usedPercent == 98)
        #expect(usage.secondary?.remainingPercent == 2)
        #expect(usage.secondary?.resetDescription == "4,900 / 5,000 credits")
        #expect(usage.secondary?.remainingPercent ?? 0 > 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `isQuotaExceeded exhausts a missing remaining counter`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.flagOnlyExhaustedOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.secondary?.remainingPercent == 0)
        #expect(
            usage.secondary?.resetDescription == nil,
            "A flag-only exhaustion must not invent a numeric balance detail")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Personal user type does not accept the organization package`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.personalOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Supplemental request is skipped after the fetch budget is consumed`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let transport = ProviderHTTPTransportHandler { request in
            requests.append(request)
            switch request.url?.path {
            case "/api/v2/me/usages/big_model_credits":
                return try Self.response(request, body: Self.memberJSON)
            case "/sash/api/v2/me/usage":
                return try Self.response(request, body: Self.organizationJSON)
            default:
                Issue.record("Unexpected Qoder request: \(request.url?.absoluteString ?? "nil")")
                return try Self.response(request, body: "{}", status: 404)
            }
        }
        let runtime = try Self.clockRuntime(engine: engine, transport: transport, now: Self.now)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Sash failure preserves the empty member snapshot`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let invalidations = StringLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.failureJSON, status: 401),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: invalidations)

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "0 / 0 credits")
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 2)
        #expect(invalidations.value.isEmpty)
    }

    private struct Presentation {
        let body: String
        let status: Int
    }

    private static func presentation(_ body: String, status: Int = 200) -> Presentation {
        Presentation(body: body, status: status)
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        presentation: Presentation,
        member: String = Self.memberJSON,
        requests: RequestLog) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "qoder",
            engine: engine,
            wallClock: self.now,
            transport: ProviderHTTPTransportHandler { request in
                requests.append(request)
                switch request.url?.path {
                case "/sash/api/v2/me/usage":
                    return try Self.response(request, body: presentation.body, status: presentation.status)
                case "/api/v2/me/usages/big_model_credits":
                    return try Self.response(request, body: member)
                default:
                    Issue.record("Unexpected Qoder request: \(request.url?.absoluteString ?? "nil")")
                    return try Self.response(request, body: "{}", status: 404)
                }
            })
    }

    private static func clockRuntime(
        engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport,
        now: Date) throws -> ProviderPluginRuntime
    {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let url = try #require(bundle.url(forResource: "qoder", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let clock = "Date.now = () => \((now.timeIntervalSince1970 + 17) * 1000);\n"
        return try ProviderPluginRuntime(
            source: clock + source,
            resourceBundle: bundle,
            transport: transport,
            timeout: 300,
            contextOptions: BundledPluginTestSupport.contextOptions,
            engine: engine)
    }

    private static func fetch(
        _ runtime: ProviderPluginRuntime,
        invalidations: StringLog) async throws -> UsageSnapshot
    {
        try await runtime.fetchUsage(
            now: self.now,
            timeZone: TimeZone(identifier: "UTC")!,
            cookieInvalidator: { domain in invalidations.append(domain) },
            cookieResolver: { _, _ in "session=fixture" })
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, HTTPURLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URLRequest] = []

        func append(_ request: URLRequest) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(request)
        }

        var value: [URLRequest] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
    }

    private final class StringLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(value)
        }

        var value: [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let refreshDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static let memberJSON = """
    {
      "quota_key": "big_model_credits",
      "status": "active",
      "total_quota": {
        "quota_summary": {
          "used_value": 0,
          "limit_value": 0,
          "remaining_value": 0,
          "usage_percentage": 0,
          "unit": "credits"
        },
        "quota_detail": []
      },
      "nextResetAt": 1767225600000
    }
    """

    private static let nonzeroMemberJSON = """
    {
      "quota_key": "big_model_credits",
      "status": "active",
      "total_quota": {
        "quota_summary": {
          "used_value": 25,
          "limit_value": 100,
          "remaining_value": 75,
          "usage_percentage": 25,
          "unit": "credits"
        },
        "quota_detail": []
      },
      "nextResetAt": 1800000000000
    }
    """

    private static let organizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": false,
        "expiresAt": 1800000000000,
        "refreshAt": 1800000000000,
        "userQuota": {
          "total": 0,
          "used": 0,
          "remaining": 0,
          "percentage": 0,
          "unit": "credits"
        },
        "orgResourcePackage": {
          "used": 1200,
          "remaining": 3800,
          "percentage": 0.24,
          "unit": "credits",
          "cap": 5000,
          "available": true
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let exhaustedOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": true,
        "expiresAt": 1800000000000,
        "refreshAt": 1800000000000,
        "userQuota": {
          "total": 0,
          "used": 0,
          "remaining": 0,
          "percentage": 0,
          "unit": "credits"
        },
        "orgResourcePackage": {
          "used": 0,
          "remaining": 0,
          "percentage": 0,
          "unit": "credits",
          "cap": 5000,
          "available": true
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let positiveBalanceOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": true,
        "expiresAt": 1800000000000,
        "refreshAt": 1800000000000,
        "userQuota": {
          "total": 0,
          "used": 0,
          "remaining": 0,
          "percentage": 0,
          "unit": "credits"
        },
        "orgResourcePackage": {
          "used": 5000,
          "remaining": 100,
          "percentage": 1,
          "unit": "credits",
          "cap": 5000,
          "available": true
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let flagOnlyExhaustedOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": true,
        "expiresAt": 1800000000000,
        "refreshAt": 1800000000000,
        "userQuota": {
          "total": 0,
          "used": 0,
          "remaining": 0,
          "percentage": 0,
          "unit": "credits"
        },
        "orgResourcePackage": {
          "used": 0,
          "percentage": 0,
          "unit": "credits",
          "cap": 5000,
          "available": true
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let personalOrganizationJSON = organizationJSON.replacingOccurrences(
        of: "\"userType\": \"teams\"",
        with: "\"userType\": \"personal\"")

    private static let failureJSON = #"{"error":"unauthorized"}"#
}
