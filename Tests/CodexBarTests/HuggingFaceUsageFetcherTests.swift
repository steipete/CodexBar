import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HuggingFaceUsageFetcherTests {
    @Test
    func `fetches credits quota and identity from all three endpoints`() async throws {
        let now = Date(timeIntervalSince1970: 1_756_600_000)
        let recorder = HuggingFaceRequestRecorder()
        let transport = Self.transport(recorder: recorder)

        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport,
            now: now)
        let requests = await recorder.values

        #expect(snapshot.credits.usedUSD == 0.45)
        #expect(snapshot.credits.includedUSD == 2.0)
        #expect(snapshot.credits.limitUSD == nil)
        #expect(snapshot.credits.requestCount == 128)
        #expect(snapshot.credits.periodEnd == Date(timeIntervalSince1970: 1_756_700_000))
        #expect(snapshot.zeroGPU?.totalSeconds == 1500)
        #expect(snapshot.zeroGPU?.remainingSeconds == 900)
        #expect(snapshot.identity?.username == "codexbar-tester")
        #expect(snapshot.identity?.email == "tester@example.com")
        #expect(snapshot.identity?.isPro == true)
        #expect(snapshot.updatedAt == now)

        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.host == "huggingface.co" })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture"
        })
        let usageURL = try #require(requests.first { $0.url?.path == "/api/settings/billing/usage-v2" }?.url)
        let queryItems = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Fixture clock: 1_756_600_000 = 2025-08-31T00:26:40Z, so the UTC month
        // start is 2025-08-01T00:00:00Z = 1754006400.
        #expect(queryItems.contains(URLQueryItem(name: "startDate", value: "1754006400")))
        #expect(queryItems.contains(URLQueryItem(name: "endDate", value: "1756600000")))
    }

    @Test
    func `whoami period end wins over usage period end`() async throws {
        // whoami.json's periodEnd (1756700000) deliberately differs from
        // usage-v2-pro.json's ISO periodEnd (1756684800 = 2025-09-01T00:00:00Z);
        // assert the resolved date is the whoami value, proving the override runs.
        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: Self.transport(recorder: HuggingFaceRequestRecorder()))
        #expect(snapshot.credits.periodEnd == Date(timeIntervalSince1970: 1_756_700_000))
    }

    @Test
    func `missing included credits fall back to spending limit`() async throws {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            usageFixture: "usage-v2-limit-only")
        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport)
        #expect(snapshot.credits.usedUSD == 1.25)
        #expect(snapshot.credits.includedUSD == 0)
        #expect(snapshot.credits.limitUSD == 5.0)
    }

    @Test
    func `no included credits and no limit decode through the fetch path`() async throws {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            usageFixture: "usage-v2-no-included")
        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport)
        #expect(snapshot.credits.usedUSD == 0.3)
        #expect(snapshot.credits.includedUSD == 0)
        #expect(snapshot.credits.limitUSD == nil)
    }

    @Test
    func `invalid token maps http 401`() async {
        let transport = Self.transport(recorder: HuggingFaceRequestRecorder(), usageStatus: 401)
        await #expect {
            _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
                apiKey: "hf_fixture",
                transport: transport)
        } throws: { error in
            error as? HuggingFaceUsageError == .invalidCredentials
        }
    }

    @Test
    func `missing billing permission maps http 403`() async {
        let transport = Self.transport(recorder: HuggingFaceRequestRecorder(), usageStatus: 403)
        await #expect {
            _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
                apiKey: "hf_fixture",
                transport: transport)
        } throws: { error in
            error as? HuggingFaceUsageError == .missingBillingPermission
        }
    }

    @Test
    func `rate limit maps http 429 with reset seconds`() async {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            usageStatus: 429,
            usageHeaders: ["RateLimit": "\"api\";r=0;t=33"])
        await #expect {
            _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
                apiKey: "hf_fixture",
                transport: transport)
        } throws: { error in
            error as? HuggingFaceUsageError == .rateLimited(retryAfterSeconds: 33)
        }
    }

    @Test
    func `drifted usage shape throws parse error`() async {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            usageFixture: "usage-v2-drifted")
        await #expect {
            _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
                apiKey: "hf_fixture",
                transport: transport)
        } throws: { error in
            guard case HuggingFaceUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `zero gpu failure is contained`() async throws {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            zeroGPUStatus: 500)
        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport)
        #expect(snapshot.zeroGPU == nil)
        #expect(snapshot.credits.usedUSD == 0.45)
    }

    @Test
    func `whoami failure is contained`() async throws {
        let transport = Self.transport(
            recorder: HuggingFaceRequestRecorder(),
            whoamiStatus: 429)
        let snapshot = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport)
        #expect(snapshot.identity == nil)
        // Without whoami, the usage-v2 ISO periodEnd is the fallback.
        #expect(snapshot.credits.periodEnd == Date(timeIntervalSince1970: 1_756_684_800))
    }

    @Test
    func `identity is cached across fetches`() async throws {
        let recorder = HuggingFaceRequestRecorder()
        let transport = Self.transport(recorder: recorder)
        let cache = HuggingFaceIdentityCache()

        _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture", transport: transport, identityCache: cache)
        let second = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture", transport: transport, identityCache: cache)

        let whoamiCalls = await recorder.values.filter { $0.url?.path == "/api/whoami-v2" }
        #expect(whoamiCalls.count == 1)
        #expect(second.identity?.username == "codexbar-tester")
    }

    @Test
    func `expired identity cache refetches`() async throws {
        let recorder = HuggingFaceRequestRecorder()
        let transport = Self.transport(recorder: recorder)
        let cache = HuggingFaceIdentityCache(ttl: 60)
        let first = Date(timeIntervalSince1970: 1_756_600_000)

        _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture", transport: transport, identityCache: cache, now: first)
        _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
            apiKey: "hf_fixture",
            transport: transport,
            identityCache: cache,
            now: first.addingTimeInterval(3600))

        let whoamiCalls = await recorder.values.filter { $0.url?.path == "/api/whoami-v2" }
        #expect(whoamiCalls.count == 2)
    }

    @Test
    func `empty token throws missing credentials`() async {
        await #expect {
            _ = try await HuggingFaceUsageFetcher._fetchUsageForTesting(
                apiKey: "   ",
                transport: Self.transport(recorder: HuggingFaceRequestRecorder()))
        } throws: { error in
            error as? HuggingFaceUsageError == .missingCredentials
        }
    }

    @Test
    func `credits map to primary window and provider cost`() {
        let snapshot = HuggingFaceUsageSnapshot(
            credits: .init(
                usedUSD: 0.45,
                includedUSD: 2.0,
                limitUSD: nil,
                requestCount: 128,
                periodEnd: Date(timeIntervalSince1970: 1_756_684_800)),
            zeroGPU: nil,
            identity: .init(username: "codexbar-tester", email: "tester@example.com", isPro: true),
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 22.5)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_756_684_800))
        #expect(usage.primary?.resetDescription == "$0.45 of $2.00 credits used")
        #expect(usage.secondary == nil)
        #expect(usage.providerCost?.used == 0.45)
        #expect(usage.providerCost?.limit == 2.0)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.identity?.accountID == "codexbar-tester")
        #expect(usage.identity?.accountEmail == "tester@example.com")
        #expect(usage.identity?.accountOrganization == "PRO")
        #expect(usage.dataConfidence == .exact)
    }

    @Test
    func `missing included credits gauge against the spending limit`() {
        let snapshot = HuggingFaceUsageSnapshot(
            credits: .init(usedUSD: 1.25, includedUSD: 0, limitUSD: 5.0, requestCount: nil, periodEnd: nil),
            zeroGPU: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25.0)
        #expect(usage.providerCost?.limit == 5.0)
        #expect(usage.primary?.resetDescription == "$1.25 of $5.00 limit used")
    }

    @Test
    func `no included credits and no limit yields zero percent and no cost`() {
        let snapshot = HuggingFaceUsageSnapshot(
            credits: .init(usedUSD: 0.3, includedUSD: 0, limitUSD: nil, requestCount: nil, periodEnd: nil),
            zeroGPU: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.providerCost == nil)
        #expect(usage.details.first?.rows.first?.value == "$0.30")
    }

    @Test
    func `zero gpu maps to secondary window and detail section`() {
        let snapshot = HuggingFaceUsageSnapshot(
            credits: .init(usedUSD: 0.45, includedUSD: 2.0, limitUSD: nil, requestCount: nil, periodEnd: nil),
            zeroGPU: .init(
                totalSeconds: 1500,
                remainingSeconds: 900,
                resetsAt: Date(timeIntervalSince1970: 1_756_663_200)),
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.secondary?.usedPercent == 40.0)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_756_663_200))
        #expect(usage.details.count == 2)
        #expect(usage.details.last?.title == "ZeroGPU")
    }

    @Test
    func `usage percent clamps at one hundred`() {
        let snapshot = HuggingFaceUsageSnapshot(
            credits: .init(usedUSD: 3.7, includedUSD: 2.0, limitUSD: nil, requestCount: nil, periodEnd: nil),
            zeroGPU: nil,
            identity: nil,
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000))
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `descriptor registers api strategy token accounts and branding`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)
        #expect(descriptor.metadata.displayName == "Hugging Face")
        #expect(descriptor.metadata.dashboardURL == "https://huggingface.co/settings/billing")
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-huggingface")
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .api]))
        #expect(descriptor.credentials?.tokenAccountSupport != nil)
    }

    // MARK: - Helpers

    private static func transport(
        recorder: HuggingFaceRequestRecorder,
        usageFixture: String = "usage-v2-pro",
        usageStatus: Int = 200,
        usageHeaders: [String: String]? = nil,
        zeroGPUStatus: Int = 200,
        whoamiStatus: Int = 200) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let path = request.url?.path ?? ""
            let data: Data
            let status: Int
            var headers: [String: String]?
            switch path {
            case "/api/settings/billing/usage-v2":
                data = usageStatus == 200 ? try Self.fixtureData(usageFixture) : Data()
                status = usageStatus
                headers = usageHeaders
            case "/api/spaces/zero-gpu/quota":
                data = zeroGPUStatus == 200 ? try Self.fixtureData("zero-gpu-quota") : Data()
                status = zeroGPUStatus
            case "/api/whoami-v2":
                data = whoamiStatus == 200 ? try Self.fixtureData("whoami") : Data()
                status = whoamiStatus
            default:
                Issue.record("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                data = Data()
                status = 500
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: headers)!
            return (data, response)
        }
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/HuggingFace"))
        return try Data(contentsOf: url)
    }
}

private actor HuggingFaceRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}
