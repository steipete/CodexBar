import Foundation
import Testing
@testable import CodexBarCore

struct T3ChatUsageFetcherTests {
    private static let now = Date(timeIntervalSince1970: 1_778_000_000)

    private static let sampleResponse = [
        #"{"json":{"0":[[0],[null,0,0]]}}"#,
        #"{"json":[0,0,[[{"result":0}],["result",0,1]]]}"#,
        #"{"json":[1,0,[[{"data":0}],["data",0,2]]]}"#,
        #"{"json":[2,0,[[{"subTier":"pro","subscription":{"# +
            #""productId":"pro","productName":"pro","status":"active","# +
            #""currentPeriodStart":1778084609000,"currentPeriodEnd":1780763009000,"# +
            #""canceledAt":null,"trialEndsAt":null},"lifetimeBalance":0,"usageBand":"max","# +
            #""billingNextResetAt":1779366216920,"usageFourHourPercentage":12.5,"# +
            #""usageMonthPercentage":34.25,"usageFourHourNextResetAt":1779366216920,"# +
            #""usagePeriodPercentage":44,"usageWindowNextResetAt":1779366216920}]]]}"#,
    ].joined(separator: "\n")

    @Test
    func `parses customer data from json lines response`() throws {
        let snapshot = try T3ChatUsageParser.parseJSONLines(Self.sampleResponse, now: Self.now)

        #expect(snapshot.customerData.subTier == "pro")
        #expect(snapshot.customerData.usageBand == "max")
        #expect(snapshot.customerData.usageFourHourPercentage == 12.5)
        #expect(snapshot.customerData.usageMonthPercentage == 34.25)
        #expect(snapshot.customerData.subscription?.status == "active")
    }

    @Test
    func `maps customer data to base and overage windows`() throws {
        let usage = try T3ChatUsageParser.parseJSONLines(Self.sampleResponse, now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 240)
        #expect(usage.primary?.resetDescription == "Base - max")
        #expect(usage.secondary?.usedPercent == 34.25)
        #expect(usage.secondary?.resetDescription == "Overage")
        #expect(usage.identity?.providerID == .t3chat)
        #expect(usage.identity?.loginMethod == "Pro")
    }

    @Test
    func `falls back to usage period percentage when month percentage is absent`() throws {
        let response = """
        {"json":[2,0,[[{"subTier":"free","usageFourHourPercentage":5,"usagePeriodPercentage":65}]]]}
        """
        let usage = try T3ChatUsageParser.parseJSONLines(response, now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 5)
        #expect(usage.secondary?.usedPercent == 65)
    }

    @Test
    func `fetch sends trpc headers and cookie`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "t3.chat")
            #expect(request.url?.path == "/api/trpc/getCustomerData")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc")
            #expect(request.value(forHTTPHeaderField: "trpc-accept") == "application/jsonl")
            #expect(request.value(forHTTPHeaderField: "x-trpc-source") == "web-client")
            #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
            #expect(request.url?.query?.contains("batch=1") == true)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }

        let snapshot = try await T3ChatUsageFetcher.fetchCustomerData(
            cookieHeader: "session=abc",
            now: Self.now,
            transport: stub)

        #expect(snapshot.customerData.planName == "Pro")
    }

    @Test
    func `full curl capture forwards browser fingerprint headers`() async throws {
        let curl = """
        curl 'https://t3.chat/api/trpc/getCustomerData?batch=1&input=ignored' \\
          -H 'User-Agent: Mozilla/5.0 Firefox/151.0' \\
          --header "Referer: https://t3.chat/settings/customization" \\
          -H 'trpc-accept: application/jsonl' \\
          -H 'x-trpc-source: web-client' \\
          -H 'x-trpc-batch: true' \\
          -H 'X-Deployment-Id: dpl_test' \\
          -H 'x-client-context: eyJjbGllbnQiOnsidmVyc2lvbiI6IjEuMTIuNCJ9fQ==' \\
          -H 'Cookie: session=abc'
        """
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 Firefox/151.0")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://t3.chat/settings/customization")
            #expect(request.value(forHTTPHeaderField: "X-Deployment-Id") == "dpl_test")
            #expect(request.value(forHTTPHeaderField: "x-client-context") ==
                "eyJjbGllbnQiOnsidmVyc2lvbiI6IjEuMTIuNCJ9fQ==")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }

        let fetcher = T3ChatUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))
        _ = try await fetcher.fetch(
            cookieHeaderOverride: curl,
            now: Self.now,
            transport: stub)
    }

    @Test
    func `curl capture forwards ansi quoted and equals header forms`() async throws {
        let curl = """
        curl 'https://t3.chat/api/trpc/getCustomerData?batch=1&input=ignored' \\
          --header=$'User-Agent: Browser\\'s Agent' \\
          --header 'X-Deployment-Id: dpl_test' \\
          -H 'Cookie: session=abc'
        """
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Browser's Agent")
            #expect(request.value(forHTTPHeaderField: "X-Deployment-Id") == "dpl_test")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }

        let fetcher = T3ChatUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))
        _ = try await fetcher.fetch(
            cookieHeaderOverride: curl,
            now: Self.now,
            transport: stub)
    }

    @Test
    func `unauthorized response is invalid credentials`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("unauthorized".utf8), response)
        }

        await #expect {
            _ = try await T3ChatUsageFetcher.fetchCustomerData(
                cookieHeader: "session=abc",
                now: Self.now,
                transport: stub)
        } throws: { error in
            guard case T3ChatUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `vercel challenge response asks for full curl capture`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["x-vercel-mitigated": "challenge"])!
            return (Data("checkpoint".utf8), response)
        }

        await #expect {
            _ = try await T3ChatUsageFetcher.fetchCustomerData(
                cookieHeader: "session=abc",
                now: Self.now,
                transport: stub)
        } throws: { error in
            guard case T3ChatUsageError.vercelChallenge = error else { return false }
            return true
        }
    }
}
