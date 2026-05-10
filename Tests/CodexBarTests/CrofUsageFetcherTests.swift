import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CrofUsageFetcherTests {
    @Test
    func `usage URL points at public usage API`() {
        #expect(CrofUsageFetcher.usageURL.absoluteString == "https://crof.ai/usage_api/")
    }

    @Test
    func `usage response parses credits and request quota`() throws {
        let json = """
        {"credits":10.0,"requests_plan":1000,"usable_requests":998}
        """

        let snapshot = try CrofUsageFetcher._parseSnapshotForTesting(Data(json.utf8))

        #expect(snapshot.credits == 10)
        #expect(snapshot.requestsPlan == 1000)
        #expect(snapshot.usableRequests == 998)
    }

    @Test
    func `usage snapshot maps usable requests to remaining quota`() {
        let snapshot = CrofUsageSnapshot(
            credits: 10,
            requestsPlan: 1000,
            usableRequests: 998,
            updatedAt: Date(timeIntervalSince1970: 1_777_800_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 1)
        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetDescription == "998 requests left")
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.resetDescription == "$10.00")
        #expect(usage.identity?.providerID == .crof)
        #expect(usage.identity?.loginMethod == "API key")
    }

    @Test
    func `usage snapshot floors credit balance to cents`() {
        let snapshot = CrofUsageSnapshot(
            credits: 9.9999,
            requestsPlan: 1000,
            usableRequests: 998)

        #expect(snapshot.toUsageSnapshot().secondary?.resetDescription == "$9.99")
    }

    @Test
    func `usage snapshot resets requests at next America Chicago midnight`() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let updatedAt = try #require(utc.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 8,
            hour: 18,
            minute: 30)))
        let expectedReset = try #require(utc.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 9,
            hour: 5)))
        let snapshot = CrofUsageSnapshot(
            credits: 10,
            requestsPlan: 1000,
            usableRequests: 998,
            updatedAt: updatedAt)

        #expect(snapshot.toUsageSnapshot().primary?.resetsAt == expectedReset)
    }

    @Test
    func `usage snapshot clamps overreported usable requests`() {
        let snapshot = CrofUsageSnapshot(
            credits: 0,
            requestsPlan: 1000,
            usableRequests: 1200)

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 0)
    }

    @Test
    func `usage snapshot treats zero plan as exhausted`() {
        let snapshot = CrofUsageSnapshot(
            credits: 0,
            requestsPlan: 0,
            usableRequests: 0)

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `fetch sends bearer token`() async throws {
        defer {
            CrofStubURLProtocol.handler = nil
            CrofStubURLProtocol.requests = []
        }
        CrofStubURLProtocol.requests = []
        CrofStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer crof-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.makeResponse(
                url: url,
                body: #"{"credits":10.0,"requests_plan":1000,"usable_requests":998}"#)
        }

        let snapshot = try await CrofUsageFetcher.fetchUsage(apiKey: "crof-test", session: Self.makeSession())

        #expect(snapshot.usableRequests == 998)
        #expect(CrofStubURLProtocol.requests.map(\.url?.absoluteString) == ["https://crof.ai/usage_api/"])
    }

    @Test
    func `descriptor supports auto and API source modes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .crof)
        #expect(descriptor.metadata.displayName == "Crof")
        #expect(descriptor.metadata.dashboardURL == "https://crof.ai/dashboard")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-crof")
    }

    @Test
    func `settings reader uses CROF_API_KEY`() {
        let token = CrofSettingsReader.apiKey(environment: [
            CrofSettingsReader.apiKeyEnvironmentKeys[0]: "  crof-token  ",
        ])

        #expect(token == "crof-token")
    }

    @Test
    func `token resolver uses crof environment token`() {
        let env = [CrofSettingsReader.apiKeyEnvironmentKeys[0]: "crof-token"]
        let resolution = ProviderTokenResolver.crofResolution(environment: env)

        #expect(resolution?.token == "crof-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `config API key override feeds crof environment`() {
        let config = ProviderConfig(id: .crof, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .crof,
            config: config)

        #expect(env[CrofSettingsReader.apiKeyEnvironmentKeys[0]] == "config-token")
        #expect(ProviderTokenResolver.crofToken(environment: env) == "config-token")
    }

    @Test
    func `config API key leaves existing crof environment token alone`() {
        let key = CrofSettingsReader.apiKeyEnvironmentKeys[0]
        let config = ProviderConfig(id: .crof, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [key: "env-token"],
            provider: .crof,
            config: config)

        #expect(env[key] == "env-token")
        #expect(ProviderTokenResolver.crofToken(environment: env) == "env-token")
    }

    @Test
    func `missing credentials fetch call throws missing credentials`() async {
        do {
            _ = try await CrofUsageFetcher.fetchUsage(apiKey: "   ")
            Issue.record("Expected missingCredentials error")
        } catch let error as CrofUsageError {
            #expect(error == .missingCredentials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CrofStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) throws -> (HTTPURLResponse, Data)
    {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])
        else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(body.utf8))
    }
}

final class CrofStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "crof.ai"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
