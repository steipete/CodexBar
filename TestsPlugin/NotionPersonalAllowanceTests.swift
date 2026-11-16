import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NotionPersonalAllowanceTests {
    private static let now = Date(timeIntervalSince1970: 1_794_585_600)
    private static let end = Date(timeIntervalSince1970: 1_795_874_400)
    private static let workspace = "11111111-2222-3333-4444-555555555555"

    private static func payload(
        _ change: (inout [String: Any]) throws -> Void = { _ in }) throws -> String
    {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(
                "Tests/CodexBarTests/Fixtures/Providers/Notion/get-credit-rate-limit-status-migrated.json")
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        try change(&value)
        return try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
    }

    private static func legacy(_ value: inout [String: Any]) throws {
        let windows = try #require(JSONSerialization.jsonObject(
            with: Data(NotionPluginTests.allowances.utf8)) as? [String: Any])
        value.merge(windows) { _, incoming in incoming }
        value["status"] = "within_limit"
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["0", "300"])
    func `live migrated fixture keeps three independent pools and exact monthly boundaries`(
        engine: ProviderPluginEngineKind, premium: String) async throws
    {
        let trace = Trace()
        let snapshot = try await Self.fetch(engine, usage: Self.payload(), premium: premium, trace: trace)
        let standard = try #require(snapshot.primary)
        let select = try #require(snapshot.secondary)
        #expect(standard.title == "Standard")
        #expect(select.title == "Select")
        #expect(abs(standard.usedPercent - 134.66869 / 1500 * 100) < 0.000000001)
        #expect(standard.quotaLimit == 1500)
        #expect(select.quotaLimit == 500)
        #expect(standard.quotaUnit == "credits")
        #expect(select.usedPercent == 0)
        #expect(standard.windowMinutes == 31 * 24 * 60)
        #expect(select.windowMinutes == standard.windowMinutes)
        #expect(standard.resetsAt == Self.end)
        #expect(select.resetsAt == Self.end)
        #expect(snapshot.detailRow(label: "Standard remaining")?.usageValue == 134.66869)
        #expect(snapshot.detailRow(label: "Select remaining")?.usageValue == 0)
        #expect(snapshot.detailRow(label: "Remaining credits")?.value == premium)
        #expect(snapshot.details.map(\.title) == ["Personal credits", "Notion Credits"])
        #expect(trace.endpoints == ["getSpaces", "getCreditRateLimitStatus", "getAIUsageEligibilityV2"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `only a resolved pool appears without duplicate legacy windows`(
        engine: ProviderPluginEngineKind) async throws
    {
        for bucket in ["auto", "flex"] {
            let usage = try Self.payload { value in
                value["allowances"] = (value["allowances"] as? [[String: Any]])?
                    .filter { $0["bucketId"] as? String == bucket }
                try Self.legacy(&value)
            }
            let snapshot = try await Self.fetch(engine, usage: usage)
            #expect(snapshot.primary?.title == (bucket == "auto" ? "Standard" : nil))
            #expect(snapshot.secondary?.title == (bucket == "flex" ? "Select" : nil))
            #expect(snapshot.primary?.windowMinutes != 360)
            #expect(snapshot.details.first?.rows.count == 1)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an invalid sibling never hides a resolved personal pool or workspace balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        for invalidBucket in ["auto", "flex"] {
            for failure in ["malformed", "unresolved", "zero-limit", "duplicate"] {
                let usage = try Self.payload { value in
                    var entries = try #require(value["allowances"] as? [[String: Any]])
                    let index = try #require(entries.firstIndex { $0["bucketId"] as? String == invalidBucket })
                    switch failure {
                    case "malformed": entries[index]["used"] = "unknown"
                    case "unresolved": entries[index]["state"] = "not_exposed"
                    case "zero-limit": entries[index]["limit"] = 0
                    default: entries.append(entries[index])
                    }
                    value["allowances"] = entries
                    try Self.legacy(&value)
                }
                let snapshot = try await Self.fetch(engine, usage: usage, premium: "300")
                let valid = try #require(invalidBucket == "auto" ? snapshot.secondary : snapshot.primary)
                #expect(valid.title == (invalidBucket == "auto" ? "Select" : "Standard"))
                #expect(valid.quotaLimit == (invalidBucket == "auto" ? 500 : 1500))
                #expect(valid.resetsAt == Self.end)
                #expect((invalidBucket == "auto" ? snapshot.primary : snapshot.secondary) == nil)
                #expect(snapshot.details.first?.rows.count == 1)
                #expect(snapshot.detailRow(label: "Remaining credits")?.value == "300")
                #expect(snapshot.detailRow(label: "\(valid.title ?? "") remaining")?.usageValue
                    == (invalidBucket == "auto" ? 0 : 134.66869))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing malformed unresolved and zero-limit pools preserve the legacy fallback`(
        engine: ProviderPluginEngineKind) async throws
    {
        let invalid: [Any] = [
            NSNull(),
            "unknown",
            [:],
            [],
            [[
                "bucketId": "auto",
                "cadence": "billing_period",
                "state": "unknown",
                "used": 0,
                "limit": 100,
            ]],
            [[
                "bucketId": "auto",
                "cadence": "billing_period",
                "state": "resolved",
                "used": 0,
                "limit": 0,
            ]],
            [[
                "bucketId": "auto",
                "cadence": "billing_period",
                "state": "resolved",
                "used": "0",
                "limit": 100,
            ]],
            [[
                "bucketId": "auto",
                "cadence": "billing_period",
                "state": "resolved",
                "used": -1,
                "limit": 100,
            ]],
            [["bucketId": "auto", "cadence": "billing_period", "state": "resolved", "used": 0]],
            [[
                "bucketId": "auto",
                "cadence": "rolling",
                "state": "resolved",
                "used": 0,
                "limit": 100,
            ]],
        ]
        for allowances in invalid {
            let usage = try Self.payload { value in
                value["allowances"] = allowances
                try Self.legacy(&value)
            }
            let snapshot = try await Self.fetch(engine, usage: usage)
            #expect(snapshot.primary?.usedPercent == 42)
            #expect(snapshot.primary?.windowMinutes == 360)
            #expect(snapshot.secondary?.usedPercent == 18)
            #expect(snapshot.primary?.title == nil)
            #expect(snapshot.details.map(\.title) == ["Notion Credits"])
        }
        let absent = try Self.payload { value in
            value.removeValue(forKey: "allowances")
            try Self.legacy(&value)
        }
        #expect(try await Self.fetch(engine, usage: absent).primary?.usedPercent == 42)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unresolved migrated pools keep valid legacy windows despite the legacy status`(
        engine: ProviderPluginEngineKind) async throws
    {
        for legacy in [true, false] {
            let usage = try Self.payload { value in
                var entries = try #require(value["allowances"] as? [[String: Any]])
                entries[1]["state"] = "unresolved"
                entries[2]["state"] = "unresolved"
                value["allowances"] = entries
                if legacy { try Self.legacy(&value) }
                value["status"] = "not_applicable"
            }
            if legacy {
                let snapshot = try await Self.fetch(engine, usage: usage)
                #expect(snapshot.primary?.usedPercent == 42)
                #expect(snapshot.secondary?.usedPercent == 18)
            } else {
                do {
                    _ = try await Self.fetch(engine, usage: usage)
                    Issue.record("Unresolved pools cannot create measured zero windows")
                } catch {
                    #expect(error.localizedDescription.contains("did not provide usable personal AI allowances"))
                    #expect(error.localizedDescription.contains("Check AI usage for the selected workspace in Notion"))
                    #expect(error.localizedDescription.contains("refresh CodexBar again"))
                }
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `ambiguous buckets and nonfinite ratios never fabricate a new balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        for duplicate in [true, false] {
            let usage = try Self.payload { value in
                var entry: [String: Any] = [
                    "bucketId": "auto",
                    "cadence": "billing_period",
                    "state": "resolved",
                    "used": 1.0,
                    "limit": 100.0,
                ]
                if !duplicate { entry["limit"] = 1e-320 }
                value["allowances"] = duplicate ? [entry, entry] : [entry]
                try Self.legacy(&value)
            }
            #expect(try await Self.fetch(engine, usage: usage).primary?.usedPercent == 42)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `exhausted and overdrawn personal credits remain distinct from zero workspace credits`(
        engine: ProviderPluginEngineKind) async throws
    {
        for used in [1500.0, 1800.0] {
            let usage = try Self.payload { value in
                var entries = try #require(value["allowances"] as? [[String: Any]])
                entries[1]["credits"] = ["used": used, "limit": 1500.0]
                value["allowances"] = entries
            }
            let snapshot = try await Self.fetch(engine, usage: usage)
            #expect(snapshot.primary?.usedPercent == used / 1500 * 100)
            #expect(snapshot.detailRow(label: "Standard remaining")?.value == "0 credits")
            #expect(snapshot.detailRow(label: "Remaining credits")?.value == "0")
            #expect(snapshot.secondary?.usedPercent == 0)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing credit counts retain known percentages without inventing zero balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try Self.payload { value in
            var entries = try #require(value["allowances"] as? [[String: Any]])
            entries[1].removeValue(forKey: "credits")
            entries[2]["credits"] = ["used": 0, "limit": 0]
            value["allowances"] = entries
        }
        let snapshot = try await Self.fetch(engine, usage: usage)
        #expect(snapshot.primary?.usedPercent == 8.98)
        #expect(snapshot.primary?.quotaLimit == nil)
        #expect(snapshot.secondary?.quotaLimit == nil)
        #expect(snapshot.detailRow(label: "Standard remaining") == nil)
        #expect(snapshot.detailRow(label: "Select remaining") == nil)
        #expect(snapshot.details.map(\.title) == ["Notion Credits"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reset boundaries are exact and missing starts never invent a pacing duration`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try Self.payload { value in
            var entries = try #require(value["allowances"] as? [[String: Any]])
            entries[1].removeValue(forKey: "periodStartMs")
            entries[2]["periodEndMs"] = 1e100
            value["allowances"] = entries
        }
        let snapshot = try await Self.fetch(engine, usage: usage)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.primary?.resetsAt == Self.end)
        #expect(snapshot.secondary?.windowMinutes == nil)
        #expect(snapshot.secondary?.resetsAt == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional visibility and failures never mix personal and workspace balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        for optional in [true, false] {
            for failure: URLError.Code? in [nil, .timedOut, .notConnectedToInternet] {
                let trace = Trace()
                let snapshot = try await Self.fetch(
                    engine, usage: Self.payload(), optional: optional, premiumError: failure, trace: trace)
                #expect(snapshot.primary?.title == "Standard")
                #expect(snapshot.secondary?.title == "Select")
                #expect(snapshot.detailRow(label: "Standard remaining")?.usageValue == 134.66869)
                #expect(snapshot.detailRow(label: "Remaining credits")?
                    .value == (optional && failure == nil ? "0" : nil))
                #expect(trace.endpoints.filter { $0 == "getAIUsageEligibilityV2" }.count == (optional ? 1 : 0))
            }
        }
        await #expect(throws: CancellationError.self) {
            try await Self.fetch(engine, usage: Self.payload(), premiumError: .cancelled)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `selected workspaces and independent sessions keep their own personal and premium pools`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (workspace, session, premium, used, limit) in [
            (Self.workspace, "first-session", "300", 134.66869, 1500.0),
            ("00000000-0000-0000-0000-000000000000", "second-session", "24", 25.0, 1000.0),
        ] {
            let usage = try Self.payload { value in
                var entries = try #require(value["allowances"] as? [[String: Any]])
                entries[1]["credits"] = ["used": used, "limit": limit]
                entries[1]["used"] = used / limit * 100
                value["allowances"] = entries
            }
            let snapshot = try await Self.fetch(
                engine, usage: usage, workspace: workspace, session: session, premium: premium)
            #expect(snapshot.detailRow(label: "Remaining credits")?.value == premium)
            #expect(snapshot.detailRow(label: "Standard remaining")?.usageValue == used)
            #expect(snapshot.primary?.quotaLimit == limit)
            #expect(snapshot.secondary?.quotaLimit == 500)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `required transport failures stop before optional credit requests`(
        engine: ProviderPluginEngineKind) async throws
    {
        for error: URLError.Code in [.timedOut, .notConnectedToInternet, .cancelled] {
            let trace = Trace()
            await #expect(throws: (any Error).self) {
                try await Self.fetch(engine, usage: Self.payload(), requiredError: error, trace: trace)
            }
            #expect(trace.endpoints == ["getSpaces", "getCreditRateLimitStatus"])
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        usage: String,
        optional: Bool = true,
        workspace: String = Self.workspace,
        session: String = "synthetic-session",
        premium: String = "0",
        premiumError: URLError.Code? = nil,
        requiredError: URLError.Code? = nil,
        trace: Trace = Trace()) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "notion",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let endpoint = try #require(request.url?.lastPathComponent)
                trace.append(endpoint)
                #expect(request.url?.host == "app.notion.com")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "token_v2=\(session)")
                let body: String
                if endpoint == "getSpaces" {
                    body = NotionPluginTests.spaces
                } else {
                    #expect(try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
                        == ["spaceId": workspace])
                    if endpoint == "getAIUsageEligibilityV2" {
                        #expect(optional)
                        #expect(request.timeoutInterval == 3)
                        if let premiumError { throw URLError(premiumError) }
                        body = "{\"premiumCredits\":{\"totalCreditBalance\":\(premium)}}"
                    } else {
                        #expect(endpoint == "getCreditRateLimitStatus")
                        if let requiredError { throw URLError(requiredError) }
                        body = usage
                    }
                }
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["WORKSPACE_ID": workspace, "OPTIONAL_USAGE": String(optional)],
            now: Self.now,
            cookieSource: .manual,
            cookieSessionResolver: { _, _ in
                .init(header: "token_v2=\(session)", source: "Fixture", origin: "https://app.notion.com", id: session)
            })
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var endpoints: [String] {
            self.lock.withLock { self.values }
        }

        func append(_ value: String) { self.lock.withLock { self.values.append(value) } }
    }
}
