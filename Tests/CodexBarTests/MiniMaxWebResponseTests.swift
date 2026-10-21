import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxWebResponseTests {
    @Test
    func `next data accepts JSON whitespace and preserves fallback for an empty script`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {"modelRemains":[{"current_interval_total_count":100,"current_interval_usage_count":75}],
         "currentSubscribeTitle":"Max"}
        """
        let html = "<script id=\"__NEXT_DATA__\"> \t\r\n\(json)\r\n\t </script>"
        #expect(try MiniMaxUsageParser.parse(html: html, now: now).planName == "Max")
        let empty = "<script id=\"__NEXT_DATA__\"> \t\r\n </script><div>Coding Plan Pro</div>"
        #expect(try MiniMaxUsageParser.parse(html: empty, now: now).planName == "Pro")
    }

    @Test
    func `next data aliases preserve snake case precedence and nested payloads`() throws {
        let payload = try MiniMaxUsageParser.decodePayload(json: ["data": [
            "modelRemains": [],
            "currentSubscribeTitle": "Current",
            "plan_name": "Original",
            "planName": "Alias",
            "comboTitle": "Combo",
            "currentPlanTitle": "Plan",
            "currentComboCard": ["title": "Card"],
            "baseResp": ["status_code": 0],
            "pointsBalance": 12.5,
            "creditsBalance": 25,
        ]])
        #expect(payload.data.modelRemains.isEmpty)
        #expect(payload.data.currentSubscribeTitle == "Current")
        #expect(payload.data.planName == "Original")
        #expect(payload.data.comboTitle == "Combo")
        #expect(payload.data.currentPlanTitle == "Plan")
        #expect(payload.data.currentComboCard?.title == "Card")
        #expect(payload.data.baseResp?.statusCode == 0)
        #expect(payload.data.pointsBalance == 12.5)
    }

    @Test(arguments: [false, true])
    func `page and remains requests preserve headers and JSON quota parsing`(fallback: Bool) async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("/charge/combo/") {
                #expect(request.value(forHTTPHeaderField: "x-group-id") == "fixture-group")
                throw URLError(.resourceUnavailable)
            }
            let isPage = url.path.contains("coding-plan")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=fixture")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "origin") == "https://platform.minimaxi.com")
            #expect(request.value(forHTTPHeaderField: "referer") ==
                "https://platform.minimaxi.com/user-center/payment/coding-plan")
            #expect(request.value(forHTTPHeaderField: "accept-language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "user-agent")?.contains("Chrome/143.0.0.0") == true)
            #expect(request.value(forHTTPHeaderField: "accept") == (isPage
                    ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                    : "application/json, text/plain, */*"))
            #expect(request.value(forHTTPHeaderField: "x-requested-with") == (isPage ? nil : "XMLHttpRequest"))
            if !isPage {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(URLQueryItem(name: "GroupId", value: "fixture-group")) == true)
            }
            let needsFallback = fallback && isPage
            let body = needsFallback ? "<html>fixture without usage</html>" : Self.usageJSON
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": needsFallback ? "text/html" : "Application/JSON; charset=utf-8"])!
            return (Data(body.utf8), response)
        }
        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=fixture",
            authorizationToken: "fixture-token",
            groupID: "fixture-group",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(snapshot.updatedAt == now)
        #expect(await transport.requests().count == (fallback ? 3 : 2))
    }

    @Test(arguments: [false, true], [401, 403, 500])
    func `page and remains failures preserve HTTP error classification`(fallback: Bool, statusCode: Int) async {
        let transport = ProviderHTTPTransportStub { request in
            let url = request.url!
            let needsFallback = fallback && url.path.contains("coding-plan")
            let response = HTTPURLResponse(
                url: url,
                statusCode: needsFallback ? 200 : statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"])!
            return (Data("<html>fixture without usage</html>".utf8), response)
        }
        let expected: MiniMaxUsageError = statusCode == 500 ? .apiError("HTTP 500") : .invalidCredentials
        await #expect(throws: expected) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "HERTZ-SESSION=fixture",
                region: .chinaMainland,
                environment: [:],
                includeBillingHistory: false,
                session: transport)
        }
        #expect(await transport.requests().count == (fallback ? 2 : 1))
    }

    private static let usageJSON = """
    {"model_remains":[{"start_time":1780279200000,"end_time":1780297200000,
    "remains_time":16659830,"model_name":"general","current_interval_total_count":0,
    "current_interval_usage_count":0,"current_interval_status":1,"current_interval_remaining_percent":96}],
    "base_resp":{"status_code":0,"status_msg":"success"}}
    """
}
