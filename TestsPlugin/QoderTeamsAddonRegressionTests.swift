import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CodexBarCore

struct QoderTeamsAddonRegressionTests {
    /// Failing regression for #5103: a Teams account can report an empty member quota while
    /// the organization resource package is still available. The fix may expose the package as
    /// primary or secondary, and may omit the zero-capacity plan; these assertions accept either
    /// presentation while rejecting the current zero-primary / no-organization behavior.
    @Test(arguments: BundledPluginTestSupport.engines)
    func `Teams zero member quota surfaces the available organization resource package`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let invalidations = StringLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.organizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: invalidations)
        let windows = Self.measuredWindows(usage)

        #expect(usage.primary?.title == "Plan credits")
        #expect(usage.secondary?.title == "Organization resource package")
        let orgWindow = windows.first { $0.resetDescription == "1,200 / 5,000 credits" }
        #expect(orgWindow != nil, "An available organization resource package must be exposed")
        #expect(orgWindow?.usedPercent == 24, "The organization resource package must report 24% used")
        #expect(orgWindow?.remainingPercent == 76, "The organization resource package must report 76% remaining")

        for window in windows where window.resetDescription == "0 / 0 credits" {
            #expect(
                window.remainingPercent == 0,
                "A retained zero-capacity plan must not look available to Automatic selection")
        }

        let resetDates = Self.resetDates(usage)
        let refreshDate = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            resetDates.contains(refreshDate),
            "The fresh plan refresh date must survive in a reset or typed plan metadata")

        let staleReset = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(
            !resetDates.contains(staleReset),
            "The stale member reset must not be used")

        let captured = requests.value
        let member = captured.first { $0.url?.path == "/api/v2/me/usages/big_model_credits" }
        let sash = captured.first { $0.url?.path == "/sash/api/v2/me/usage" }
        #expect(member?.httpMethod == "GET")
        #expect(sash?.httpMethod == "GET")
        #expect(member?.url?.host == "qoder.com")
        #expect(sash?.url?.host == "qoder.com")
        #expect(member?.value(forHTTPHeaderField: "Origin") == "https://qoder.com")
        #expect(sash?.value(forHTTPHeaderField: "Origin") == "https://qoder.com")
        #expect(member?.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(sash?.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(captured.allSatisfy { $0.url?.host == "qoder.com" })
        #expect(invalidations.value.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Teams personal add-on is used when the organization package is unavailable`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.personalAddOnJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())
        let windows = Self.measuredWindows(usage)

        #expect(usage.secondary?.title == "Add-on credits")
        let addOnWindow = windows.first { $0.resetDescription == "500 / 2,000 credits" }
        #expect(addOnWindow != nil, "An available personal add-on must be exposed")
        #expect(addOnWindow?.usedPercent == 25)
        #expect(addOnWindow?.remainingPercent == 75)
        #expect(
            !windows.contains { $0.resetDescription == "1,000 / 5,000 credits" },
            "An unavailable organization package must not become a measured window even with a positive balance")
        #expect(requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Teams personal add-on is used when the organization package is exhausted`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.exhaustedOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())
        let windows = Self.measuredWindows(usage)

        #expect(usage.secondary?.title == "Add-on credits")
        #expect(
            usage.extraRateWindows?.first { $0.id == "qoder-org-resource-package" }?.title
                == "Organization resource package")
        let addOnWindow = windows.first { $0.resetDescription == "500 / 2,000 credits" }
        #expect(
            addOnWindow != nil,
            "An available personal add-on must be exposed when the organization pool is exhausted")
        #expect(addOnWindow?.usedPercent == 25)
        #expect(addOnWindow?.remainingPercent == 75)
        for window in windows where window.resetDescription == "5,000 / 5,000 credits" {
            #expect(window.remainingPercent == 0, "An exhausted organization package must not look available")
        }
        #expect(requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Organization and personal add-on pools keep distinct names`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.bothPoolsJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.title == "Plan credits")
        #expect(usage.secondary?.title == "Organization resource package")
        #expect(usage.secondary?.resetDescription == "1,200 / 5,000 credits")
        let addOn = usage.extraRateWindows?.first { $0.id == "qoder-add-on" }
        #expect(addOn?.title == "Add-on credits")
        #expect(addOn?.usageKnown == true)
        #expect(addOn?.window.resetDescription == "500 / 2,000 credits")
        #expect(requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Supplemental timeout honors configured and remaining budgets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let cases: [(settings: [String: String], expected: Double)] = [
            (["REQUEST_TIMEOUT": "1"], 1),
            (["REQUEST_DEADLINE_MILLIS": String(Self.now.addingTimeInterval(2).timeIntervalSince1970 * 1000)], 1),
        ]
        for testCase in cases {
            let requests = RequestLog()
            let runtime = try Self.runtime(
                engine: engine,
                presentation: Self.presentation(Self.organizationJSON),
                requests: requests)
            _ = try await Self.fetch(runtime, invalidations: StringLog(), settings: testCase.settings)
            let sash = try #require(requests.value.first { $0.url?.path == "/sash/api/v2/me/usage" })
            #expect(sash.timeoutInterval == testCase.expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Non-empty member plan skips the supplemental request`(
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
        #expect(usage.primary?.title == "Plan credits")
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 1)
        #expect(!requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Supplemental request is skipped when the host deadline is close`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let deadline = Self.now.addingTimeInterval(0.5).timeIntervalSince1970 * 1000
        let settings = ["REQUEST_DEADLINE_MILLIS": String(deadline)]
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.organizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog(), settings: settings)

        #expect(usage.primary?.resetDescription == "0 / 0 credits")
        #expect(usage.primary?.title == "Plan credits")
        #expect(requests.value.count == 1)
        #expect(!requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Legacy shared member credits keep the aggregate label`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.organizationJSON),
            member: Self.sharedMemberJSON,
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())

        #expect(usage.primary?.title == "Credits")
        #expect(usage.primary?.usedPercent == 68)
        #expect(usage.primary?.resetDescription == "1,700 / 2,500 credits")
        #expect(usage.secondary == nil)
        #expect(requests.value.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["401", "403", "404", "malformed", "empty-object", "long-unit"])
    func `Sash failure preserves the member snapshot without invalidating the cookie`(
        engine: ProviderPluginEngineKind,
        failure: String) async throws
    {
        let requests = RequestLog()
        let invalidations = StringLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.failurePresentation(failure),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: invalidations)
        let windows = Self.measuredWindows(usage)

        let staleReset = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(usage.primary?.resetDescription == "0 / 0 credits")
        #expect(usage.primary?.title == "Plan credits")
        #expect(
            usage.primary?.resetsAt == staleReset,
            "The member snapshot must survive the supplemental failure")
        #expect(!windows.contains { $0.resetDescription == "1,200 / 5,000 credits" })
        #expect(!windows.contains { $0.resetDescription == "500 / 2,000 credits" })

        let captured = requests.value
        let member = captured.filter { $0.url?.path == "/api/v2/me/usages/big_model_credits" }
        let sash = captured.filter { $0.url?.path == "/sash/api/v2/me/usage" }
        #expect(captured.count == 2, "The fallback must not traverse extra candidates")
        #expect(member.count == 1)
        #expect(sash.count == 1)
        #expect(captured.allSatisfy { $0.url?.host == "qoder.com" })
        #expect(invalidations.value.isEmpty, "A supplemental failure must not reject the cookie")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `All-empty presentation does not invent a credit window`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.emptyJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())
        let windows = Self.measuredWindows(usage)

        #expect(
            windows.allSatisfy { $0.remainingPercent <= 0 },
            "An all-empty presentation must not invent available credits")
        #expect(usage.primary?.title == "Plan credits")
        #expect(requests.value.contains { $0.url?.path == "/sash/api/v2/me/usage" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Invalid supplemental refresh falls back to expiresAt`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.invalidRefreshOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())
        let refreshDate = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Self.measuredWindows(usage).contains { $0.resetsAt == refreshDate })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Missing supplemental dates retain the member reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            presentation: Self.presentation(Self.noDateOrganizationJSON),
            requests: requests)
        let usage = try await Self.fetch(runtime, invalidations: StringLog())
        let staleReset = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(usage.primary?.resetsAt == staleReset)
        #expect(Self.measuredWindows(usage).contains { $0.resetDescription == "1,200 / 5,000 credits" })
    }

    private struct Presentation {
        let body: String
        let status: Int
    }

    private static let now = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-28

    private static func presentation(_ body: String) -> Presentation {
        Presentation(body: body, status: 200)
    }

    private static func failurePresentation(_ failure: String) -> Presentation {
        switch failure {
        case "401":
            return Presentation(body: #"{"error":"unauthorized"}"#, status: 401)
        case "403":
            return Presentation(body: #"{"error":"forbidden"}"#, status: 403)
        case "404":
            return Presentation(body: #"{"error":"not found"}"#, status: 404)
        case "empty-object":
            return Presentation(body: #"{"displayMode":"qoder","qoderUsage":{}}"#, status: 200)
        case "long-unit":
            let unit = String(repeating: "x", count: 40)
            let body = """
            {
              "displayMode": "qoder",
              "qoderUsage": {
                "userQuota": {
                  "total": 0,
                  "used": 0,
                  "remaining": 0,
                  "percentage": 0,
                  "unit": "\(unit)"
                }
              }
            }
            """
            return Presentation(body: body, status: 200)
        default:
            return Presentation(body: "not json", status: 200)
        }
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

    private static func fetch(
        _ runtime: ProviderPluginRuntime,
        invalidations: StringLog,
        settings: [String: String] = [:]) async throws -> UsageSnapshot
    {
        try await runtime.fetchUsage(
            settings: settings,
            now: self.now,
            timeZone: TimeZone(identifier: "UTC")!,
            cookieInvalidator: { domain in invalidations.append(domain) },
            cookieResolver: { _, _ in "session=fixture" })
    }

    private static func measuredWindows(_ usage: UsageSnapshot) -> [RateWindow] {
        [usage.primary, usage.secondary, usage.tertiary].compactMap(\.self)
            + (usage.extraRateWindows ?? []).filter(\.usageKnown).map(\.window)
    }

    private static func resetDates(_ usage: UsageSnapshot) -> [Date] {
        ([usage.primary, usage.secondary, usage.tertiary].compactMap(\.self)
            + (usage.extraRateWindows ?? []).map(\.window))
            .compactMap(\.resetsAt)
            + [usage.subscriptionRenewsAt].compactMap(\.self)
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

    private static let memberJSON = """
    {
      "user_id": "<redacted>",
      "quota_key": "big_model_credits",
      "status": "active",
      "plan_quota": {
        "quota_summary": {
          "used_value": 0,
          "limit_value": 0,
          "remaining_value": 0,
          "usage_percentage": 0,
          "unit": "credits"
        },
        "quota_detail": []
      },
      "resource_package_quota": {
        "quota_summary": {
          "used_value": 0,
          "limit_value": 0,
          "remaining_value": 0,
          "usage_percentage": 0,
          "unit": "credits"
        },
        "quota_detail": null
      },
      "dedicated_resource_package_quota": {
        "quota_summary": {
          "used_value": 0,
          "limit_value": 0,
          "remaining_value": 0,
          "usage_percentage": 0,
          "unit": "credits"
        },
        "quota_detail": null
      },
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
      "lastResetAt": 1735689600000,
      "nextResetAt": 1767225600000
    }
    """

    private static let organizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userId": "<redacted>",
        "userType": "teams",
        "usageType": "credits",
        "totalUsagePercentage": 0,
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

    private static let personalAddOnJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userId": "<redacted>",
        "userType": "teams",
        "usageType": "credits",
        "totalUsagePercentage": 0,
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
          "used": 1000,
          "remaining": 4000,
          "percentage": 0.2,
          "unit": "credits",
          "cap": 5000,
          "available": false
        },
        "addOnQuota": {
          "total": 2000,
          "used": 500,
          "remaining": 1500,
          "percentage": 0.25,
          "unit": "credits"
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let exhaustedOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userId": "<redacted>",
        "userType": "teams",
        "usageType": "credits",
        "totalUsagePercentage": 0,
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
          "used": 5000,
          "remaining": 0,
          "percentage": 1,
          "unit": "credits",
          "cap": 5000,
          "available": true
        },
        "addOnQuota": {
          "total": 2000,
          "used": 500,
          "remaining": 1500,
          "percentage": 0.25,
          "unit": "credits"
        },
        "isPlanQuotaProrated": false
      }
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

    private static let invalidRefreshOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": false,
        "refreshAt": "not-a-date",
        "expiresAt": 1800000000000,
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
        }
      }
    }
    """

    private static let noDateOrganizationJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userType": "teams",
        "usageType": "credits",
        "isQuotaExceeded": false,
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
        }
      }
    }
    """

    private static let bothPoolsJSON = """
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
        "addOnQuota": {
          "total": 2000,
          "used": 500,
          "remaining": 1500,
          "percentage": 0.25,
          "unit": "credits"
        },
        "isPlanQuotaProrated": false
      }
    }
    """

    private static let sharedMemberJSON = """
    {
      "quota_key": "big_model_credits",
      "status": "active",
      "total_quota": {
        "quota_summary": {
          "used_value": 1500,
          "limit_value": 1500,
          "remaining_value": 0,
          "usage_percentage": 100,
          "unit": "credits"
        },
        "quota_detail": []
      },
      "shared_quota": {
        "quota_summary": {
          "used_value": 200,
          "limit_value": 1000,
          "remaining_value": 800,
          "usage_percentage": 20,
          "unit": "credits"
        },
        "quota_detail": []
      },
      "nextResetAt": 1800000000000
    }
    """

    private static let emptyJSON = """
    {
      "displayMode": "qoder",
      "qoderUsage": {
        "userId": "<redacted>",
        "userType": "teams",
        "usageType": "credits",
        "totalUsagePercentage": 0,
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
        "isPlanQuotaProrated": false
      }
    }
    """
}
