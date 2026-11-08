import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxCookieNormalizationRegressionTests {
    private static let cookie = "analytics=abc-Bdef; _token=fixture-token; minimax_group_id_v2=123456789"

    @Test
    func `normalizing browser cookies is idempotent when values contain curl option text`() throws {
        let cookie = Self.cookie
        let inputs = [
            cookie,
            "Cookie: \(cookie)",
            "'\(cookie)'",
            "\"\(cookie)\"",
            "curl https://www.minimax.cn/quota -H 'Cookie: \(cookie)'",
            "curl https://www.minimax.cn/quota -b '\(cookie)'",
            "curl https://www.minimax.cn/quota --cookie \"\(cookie)\"",
        ]

        for input in inputs {
            let normalized = try #require(MiniMaxCookieHeader.normalized(from: input))
            #expect(normalized == cookie)
            #expect(MiniMaxCookieHeader.normalized(from: normalized) == cookie)
        }
    }

    @Test(arguments: ["-b", "--cookie", "-B"])
    func `curl option substrings inside raw values remain intact`(option: String) {
        let cookie = "analytics=prefix\(option)suffix; _token=fixture-token"
        #expect(MiniMaxCookieHeader.normalized(from: cookie) == cookie)
    }

    @Test
    func `compact curl cookie option remains supported`() {
        let cookie = "analytics=abc-Bdef"
        #expect(MiniMaxCookieHeader.normalized(from: "curl https://www.minimax.cn/quota -b\(cookie)") == cookie)
    }

    @Test
    func `curl override preserves bearer and group alongside option like cookie values`() throws {
        let raw = """
        curl 'https://www.minimax.cn/backend/account/token_plan/remains_percent' \
          -b '\(Self.cookie)' \
          -H 'authorization: Bearer fixture.token-signature' \
          -H 'x-group-id: 987654321'
        """

        let override = try #require(MiniMaxCookieHeader.override(from: raw))
        #expect(override.cookieHeader == Self.cookie)
        #expect(override.authorizationToken == "fixture.token-signature")
        #expect(override.groupID == "987654321")
        #expect(MiniMaxCookieHeader.normalized(from: override.cookieHeader) == Self.cookie)
    }

    @Test
    func `web fetch preserves a previously normalized browser cookie header`() async throws {
        let raw = "curl https://www.minimax.cn/quota -b '\(Self.cookie)'"
        let override = try #require(MiniMaxCookieHeader.override(from: raw))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("/charge/combo/") {
                throw URLError(.resourceUnavailable)
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == Self.cookie)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let isPage = url.path == "/console/usage"
            if !isPage {
                #expect(request.value(forHTTPHeaderField: "X-Group-Id") == "123456789")
            }
            let body = isPage ? "<html>fixture without usage</html>" : """
            {"base_resp":{"status_code":0},"model_remains":[{
              "current_interval_used_percent":"25%","current_interval_total_percent":"100%",
              "current_interval_status":1
            }]}
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": isPage ? "text/html" : "application/json"])!
            return (Data(body.utf8), response)
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: override.cookieHeader,
            authorizationToken: override.authorizationToken,
            groupID: override.groupID,
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport)

        #expect(snapshot.usedPercent == 25)
    }
}
