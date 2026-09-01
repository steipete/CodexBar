import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct MuseWebUsageFetcherTests {
    @Test
    func `parses rendered usage dashboard text`() throws {
        let text = """
        Usage
        08/26/26 - 09/01/26
        7d
        $3.08
        Spend (USD)
        294.1M
        Input tokens
        1.5M
        Output tokens
        3.0k
        Requests
        """

        let snapshot = try #require(MuseWebUsageFetcher.parseRenderedDashboardText(text))
        #expect(snapshot.providerCost?.used == 3.08)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Last 7 days")
        #expect(snapshot.identity == nil)
    }

    @Test
    func `ignores token and request totals without spend`() {
        let text = """
        Usage
        08/26/26 - 09/01/26
        7d
        294.1M
        Input tokens
        1.5M
        Output tokens
        3.0k
        Requests
        """

        #expect(MuseWebUsageFetcher.parseRenderedDashboardText(text) == nil)
    }

    @Test
    func `presents dashboard spend as pay as you go cost`() throws {
        let snapshot = try #require(MuseWebUsageFetcher.parseRenderedDashboardText("$3.08\nSpend (USD)"))
        let style = MuseProviderDescriptor.descriptor.presentation
            .cost(snapshot: snapshot)
            .menuCardStyle

        #expect(style == .payAsYouGoSpend)
    }

    @Test
    func `builds relay request from current dashboard context`() async throws {
        let recorder = MuseWebRequestRecorder()
        let html =
            #""teamId":"1111111111111111","LSD",[],{"token":"live-lsd-token"},"# +
            #""DTSGInitialData":{"token":"live-dtsg-token:1"},"USER_ID":"2222222222222222","# +
            #""__rev":1000000000,"hsi":"3333333333333333333""#
        let responseJSON =
            #"{"data":{"team":{"spend_cost_metrics":[{"identifier":"usage_billable_cost","# +
            #""categorical_data":[{"category":"2026-08-30","value":{"amount_with_offset":"125"}}]}]}}}"#
        let transport = MuseWebStubTransport { request in
            recorder.append(request)
            if request.httpMethod == "POST" {
                return Self.response(request, body: responseJSON)
            }
            return Self.response(request, body: html)
        }

        let dashboardURL = try #require(URL(
            string: "https://dev.meta.ai/usage/?team_id=1111111111111111&project_id=project-1"))
        _ = try await MuseWebUsageFetcher.fetchUsage(
            cookieHeader: "llm_sess=current",
            dashboardURL: dashboardURL,
            userAgent: "Muse-Test-Browser/152",
            transport: transport)

        let requests = recorder.requests
        #expect(requests.count == 2)
        let dashboard = try #require(requests.first)
        #expect(
            dashboard.url?.absoluteString ==
                "https://dev.meta.ai/usage/?team_id=1111111111111111&project_id=project-1")
        #expect(dashboard.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "navigate")
        #expect(dashboard.value(forHTTPHeaderField: "Sec-Fetch-Dest") == "document")
        #expect(dashboard.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == "1")
        #expect(dashboard.value(forHTTPHeaderField: "Sec-CH-UA")?.contains(#""Chromium";v="152""#) == true)
        let graphQL = try #require(requests.last)
        #expect(graphQL.url?.path == "/api/graphql")
        #expect(graphQL.value(forHTTPHeaderField: "Cookie") == "llm_sess=current")
        #expect(graphQL.value(forHTTPHeaderField: "X-FB-LSD") == "live-lsd-token")
        #expect(graphQL.value(forHTTPHeaderField: "User-Agent") == "Muse-Test-Browser/152")
        #expect(graphQL.value(forHTTPHeaderField: "Referer") == dashboard.url?.absoluteString)

        let body = try #require(graphQL.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let params = Self.formValues(body)
        #expect(params["doc_id"] == "28117303444603430")
        #expect(params["fb_dtsg"] == "live-dtsg-token:1")
        #expect(params["av"] == "2222222222222222")
        #expect(params["__user"] == "2222222222222222")
        #expect(params["__dyn"] == nil)
        #expect(params["__csr"] == nil)
        #expect(params["__spin_t"] == nil)

        let variablesData = try #require(params["variables"]?.data(using: .utf8))
        let variables = try #require(
            JSONSerialization.jsonObject(with: variablesData) as? [String: Any])
        #expect(variables["team_id"] as? String == "1111111111111111")
        #expect(variables["month"] is NSNull)
        #expect(variables["timezone"] == nil)
        #expect(
            variables["__relay_internal__pv__Usage_ShouldIncludeSubscriptionQuotarelayprovider"] as? Bool == true)
        let startDate = try #require(variables["start_date"] as? String)
        let endDate = try #require(variables["end_date"] as? String)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = try #require(formatter.date(from: startDate))
        let end = try #require(formatter.date(from: endDate))
        #expect(Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day == 6)
    }

    @Test
    func `does not mislabel a dashboard server error as an invalid session`() async throws {
        let recorder = MuseWebRequestRecorder()
        let transport = MuseWebStubTransport { request in
            recorder.append(request)
            return Self.response(request, statusCode: 500, body: "server error")
        }

        await #expect {
            _ = try await MuseWebUsageFetcher.fetchUsage(
                cookieHeader: "llm_sess=current",
                transport: transport)
        } throws: { error in
            guard case let MuseUsageError.apiError(message) = error else { return false }
            return message == "HTTP 500 at /usage/"
        }
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.map(\.url?.path) == ["/usage", "/"])
    }

    @Test
    func `bootstraps from the app shell when the client routed dashboard returns 500`() async throws {
        let recorder = MuseWebRequestRecorder()
        let html =
            #""LSD",[],{"token":"live-lsd-token"},"DTSGInitialData":{"token":"live-dtsg-token:1"}"#
        let responseJSON =
            #"{"data":{"team":{"spend_cost_metrics":[{"identifier":"usage_billable_cost","# +
            #""categorical_data":[{"category":"2026-08-30","value":{"amount_with_offset":"125"}}]}]}}}"#
        let transport = MuseWebStubTransport { request in
            recorder.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/graphql"):
                return Self.response(request, body: responseJSON)
            case (_, "/usage"):
                return Self.response(request, statusCode: 500, body: "server error")
            default:
                return Self.response(request, body: html)
            }
        }

        let dashboardURL = try #require(URL(
            string: "https://dev.meta.ai/usage/?team_id=1111111111111111&project_id=project-1"))
        _ = try await MuseWebUsageFetcher.fetchUsage(
            cookieHeader: "llm_sess=current",
            dashboardURL: dashboardURL,
            userAgent: "Muse-Test-Browser/152",
            transport: transport)

        let requests = recorder.requests
        #expect(requests.map(\.url?.path) == ["/usage", "/", "/api/graphql"])
        #expect(requests[1].url?.query?.contains("team_id=") == true)
        #expect(requests[1].url?.query?.contains("project_id=") == true)
        #expect(requests[1].value(forHTTPHeaderField: "User-Agent") == "Muse-Test-Browser/152")
        #expect(requests.last?.value(forHTTPHeaderField: "Referer") == dashboardURL.absoluteString)
    }

    @Test
    func `uses minimal relay request when Meta rejects browser document routes`() async throws {
        let recorder = MuseWebRequestRecorder()
        let responseJSON =
            #"{"data":{"team":{"spend_cost_metrics":[{"identifier":"usage_billable_cost","# +
            #""categorical_data":[{"category":"2026-08-30","value":{"amount_with_offset":"125"}}]}]}}}"#
        let transport = MuseWebStubTransport { request in
            recorder.append(request)
            if request.httpMethod == "POST" {
                return Self.response(request, body: responseJSON)
            }
            return Self.response(request, statusCode: 500, body: "server error")
        }

        let dashboardURL = try #require(URL(
            string: "https://dev.meta.ai/usage/?team_id=1111111111111111&project_id=project-1"))
        _ = try await MuseWebUsageFetcher.fetchUsage(
            cookieHeader: "llm_sess=current",
            dashboardURL: dashboardURL,
            userAgent: "Muse-Test-Browser/152",
            transport: transport)

        let requests = recorder.requests
        #expect(requests.map(\.url?.path) == ["/usage", "/", "/api/graphql"])
        let graphQL = try #require(requests.last)
        let body = try #require(graphQL.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let params = Self.formValues(body)
        #expect(params["lsd"] == nil)
        #expect(params["fb_dtsg"] == nil)
        let variablesData = try #require(params["variables"]?.data(using: .utf8))
        let variables = try #require(JSONSerialization.jsonObject(with: variablesData) as? [String: Any])
        #expect(variables["team_id"] as? String == "1111111111111111")
    }

    @Test
    func `surfaces relay errors without a fallback retry`() async throws {
        let recorder = MuseWebRequestRecorder()
        let html = #"{"teamId":"1111111111111111","LSD",[],{"token":"live-lsd-token"}}"#
        let errorJSON = #"{"errors":[{"message":"Rate limit exceeded","code":1675004}]}"#
        let transport = MuseWebStubTransport { request in
            recorder.append(request)
            return Self.response(request, body: request.httpMethod == "POST" ? errorJSON : html)
        }

        await #expect {
            _ = try await MuseWebUsageFetcher.fetchUsage(
                cookieHeader: "llm_sess=current",
                transport: transport)
        } throws: { error in
            guard case let MuseUsageError.apiError(message) = error else { return false }
            return message == "GraphQL 1675004: Rate limit exceeded"
        }
        #expect(recorder.requests.count == 2)
    }

    @Test
    func `parses team usage inside a comet relay envelope`() throws {
        let responseJSON =
            #"{"__ar":1,"payload":{"data":{"team":{"requests_metrics":[{"identifier":"num_requests","# +
            #""categorical_data":[{"category":"2026-09-01","value":7}]}],"# +
            #""input_token_metrics":[{"identifier":"num_prompt_tokens","# +
            #""categorical_data":[{"category":"2026-09-01","value":100}]}],"# +
            #""output_token_metrics":[{"identifier":"num_completion_tokens","# +
            #""categorical_data":[{"category":"2026-09-01","value":25}]}],"# +
            #""spend_cost_metrics":[{"identifier":"usage_billable_cost","categorical_data":["# +
            #"{"category":"2026-08-31","value":{"amount_with_offset":"183"}},"# +
            #"{"category":"2026-09-01","value":{"amount_with_offset":"125"}}]}]}}}}"#

        let snapshot = try #require(try MuseWebUsageFetcher.parseUsageGraphQL(data: Data(responseJSON.utf8)))
        #expect(snapshot.providerCost?.used == 3.08)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Last 7 days")
        #expect(snapshot.identity == nil)
        #expect(snapshot.details.first?.title == "Daily spend")
        #expect(snapshot.details.first?.rows.map(\.value) == ["$1.83", "$1.25"])
    }

    @Test
    func `strips spaced meta javascript response guard`() {
        let guarded = Data(#"for (;;);{"data":{"team":null}}"#.utf8)
        let stripped = MuseWebUsageFetcher.stripJSWrapper(guarded)
        #expect(String(data: stripped, encoding: .utf8) == #"{"data":{"team":null}}"#)
    }

    @Test
    func `surfaces comet error envelopes`() {
        let data = Data(
            #"{"__ar":1,"error":1357004,"errorSummary":"Invalid request","errorDescription":"Try again"}"#.utf8)
        #expect(MuseWebUsageFetcher.graphQLError(from: data) == "GraphQL 1357004: Invalid request: Try again")
    }

    @Test
    func `extracts current comet tokens`() {
        let html = #""LSD",[],{"token":"lsd-now"},"DTSGInitialData":{"token":"dtsg-now:2"},"USER_ID":"1234567890""#
        #expect(MuseWebUsageFetcher.extractLSD(from: html) == "lsd-now")
        #expect(MuseWebUsageFetcher.extractFbDtsg(from: html) == "dtsg-now:2")
        #expect(MuseWebUsageFetcher.extractActorID(from: html) == "1234567890")
        #expect(MuseWebUsageFetcher.jazoest(for: "A") == "265")
    }

    private static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        body: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func formValues(_ body: String) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private final class MuseWebRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        self.lock.withLock { self.storage }
    }

    func append(_ request: URLRequest) {
        self.lock.withLock { self.storage.append(request) }
    }
}

private struct MuseWebStubTransport: ProviderHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (response, data) = try self.handler(request)
        return (data, response)
    }
}
