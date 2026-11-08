import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxWebCredentialErrorTests {
    @Test(arguments: [false, true], ["invalid api key", " INVALID API KEY \n"])
    func `invalid api key responses are retryable credential failures`(nested: Bool, message: String) throws {
        let error: [String: Any] = ["status_code": 1001, "status_msg": message]
        let payload: [String: Any] = nested
            ? ["data": ["base_resp": error]]
            : ["base_resp": error]
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: data)
        }
    }

    @Test(arguments: ["service unavailable", "invalid api key scope"])
    func `other service errors retain their API classification`(message: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "base_resp": ["status_code": 1001, "status_msg": message],
        ])

        #expect(throws: MiniMaxUsageError.apiError(message)) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: data)
        }
    }

    @Test(arguments: [false, true])
    func `page and quota reject invalid web credentials without endpoint fallback`(fallback: Bool) async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isPage = url.path == "/console/usage"
            let needsFallback = fallback && isPage
            let body = needsFallback ? "<html>fixture without usage</html>" : """
            {"base_resp":{"status_code":1001,"status_msg":"invalid api key"}}
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": needsFallback ? "text/html" : "application/json"])!
            return (Data(body.utf8), response)
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "_token=expired-fixture",
                region: .chinaMainland,
                environment: [:],
                includeBillingHistory: false,
                session: transport)
        }
        #expect(await transport.requests().count == (fallback ? 2 : 1))
    }
}
