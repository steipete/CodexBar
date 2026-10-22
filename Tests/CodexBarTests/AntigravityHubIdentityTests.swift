import Foundation
import Testing
@testable import CodexBarCore

private actor AntigravityHubRequestCapture {
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }

    func values() -> [URLRequest] {
        self.requests
    }
}

struct AntigravityHubIdentityTests {
    @Test(arguments: ["shared", "selected-a", "selected-b"], [true, false])
    func `quota requests use the Hub identity for every credential source`(
        account: String, summaryAvailable: Bool) async throws
    {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "shared-token",
            refreshToken: "shared-refresh",
            expiry: Date(timeIntervalSince1970: 1),
            email: "shared@example.com",
            clientID: "synthetic-client",
            clientSecret: "synthetic-secret")
        let selected = AntigravityOAuthCredentials(
            accessToken: "\(account)-token",
            refreshToken: "\(account)-refresh",
            expiryDate: Date(timeIntervalSince1970: 1),
            email: "\(account)@example.com",
            clientID: "synthetic-client",
            clientSecret: "synthetic-secret")
        let environment = try account == "shared" ? [:] : [
            AntigravityOAuthCredentialsStore.environmentCredentialsKey:
                AntigravityOAuthCredentialsStore.tokenAccountValue(for: selected),
        ]
        let capture = AntigravityHubRequestCapture()
        let loader: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await capture.append(request)
            let url = try #require(request.url)
            let payload: Data
            var statusCode = 200
            if url.host == "oauth2.googleapis.com" {
                #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
                #expect(try FormBodyTestSupport.decode(#require(request.httpBody))["refresh_token"] ==
                    "\(account)-refresh")
                payload = GeminiAPITestHelpers.jsonData([
                    "access_token": "\(account)-refreshed", "expires_in": 3600,
                ])
            } else {
                #expect(url.host == "cloudcode-pa.googleapis.com" ||
                    url.host == "daily-cloudcode-pa.googleapis.com")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(account)-refreshed")
                switch url.path {
                case "/v1internal:loadCodeAssist":
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["metadata"] as? [String: String] == [
                        "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI",
                    ])
                    payload = GeminiAPITestHelpers.jsonData([
                        "allowedTiers": [["id": "standard-tier", "isDefault": true]],
                    ])
                case "/v1internal:onboardUser":
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["metadata"] as? [String: String] == [
                        "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI",
                    ])
                    #expect(json["tierId"] as? String == "standard-tier")
                    payload = GeminiAPITestHelpers.jsonData([
                        "response": ["cloudaicompanionProject": ["id": " \(account)-project \n"]],
                    ])
                case "/v1internal:retrieveUserQuotaSummary" where summaryAvailable:
                    payload = Data(antigravityQuotaSummaryJSON(
                        geminiSession: url.host == "daily-cloudcode-pa.googleapis.com" ? 0.88 : 1,
                        geminiWeekly: url.host == "daily-cloudcode-pa.googleapis.com" ? 0 : 0.69).utf8)
                case "/v1internal:retrieveUserQuota":
                    payload = GeminiAPITestHelpers.sampleQuotaResponse()
                default:
                    statusCode = 403
                    payload = Data()
                }
                if ["retrieveUserQuotaSummary", "fetchAvailableModels", "retrieveUserQuota"]
                    .contains(where: { url.path.hasSuffix($0) })
                {
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                    #expect(json["project"] == "\(account)-project")
                }
            }
            let (response, data) = GeminiAPITestHelpers.response(
                url: url.absoluteString, status: statusCode, body: payload)
            return (data, response)
        }
        let snapshot = try await AntigravityRemoteUsageFetcher(
            homeDirectory: env.homeURL.path,
            environment: environment,
            dataLoader: loader,
            oauthClientResolver: { nil }).fetch()
        #expect(snapshot.accountEmail == "\(account)@example.com")
        #expect(snapshot.hasKnownQuotaSummary == summaryAvailable)
        #expect(summaryAvailable || snapshot.modelQuotas.count == 3)
        if summaryAvailable {
            let usage = try snapshot.toUsageSnapshot()
            #expect(usage.extraRateWindows?.prefix(2).map { $0.window.remainingPercent.rounded() } == [88, 0])
        }

        let requests = await capture.values()
        let cloudRequests = requests.filter { $0.url?.host == "cloudcode-pa.googleapis.com" }
        let expectedCloudPaths = ["loadCodeAssist", "onboardUser"] +
            (summaryAvailable ? [] : ["fetchAvailableModels", "retrieveUserQuota"])
        #expect(cloudRequests.map { $0.url?.path } == expectedCloudPaths.map { "/v1internal:\($0)" })
        let dailyRequests = requests.filter { $0.url?.host == "daily-cloudcode-pa.googleapis.com" }
        #expect(dailyRequests.map { $0.url?.path } == ["/v1internal:retrieveUserQuotaSummary"])
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        #if os(Linux)
        let platform = "linux"
        #else
        let platform = "darwin"
        #endif
        for request in cloudRequests + dailyRequests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") ==
                "antigravity/hub/2.9.1 \(platform)/\(architecture)")
        }
        if account != "shared" {
            let shared = try AntigravityOAuthCredentialsStore(
                fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: env.homeURL)).load()
            #expect(shared?.accessToken == "shared-token")
        }
    }
}
