import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Qwen Cloud token-plan gateway client.
///
/// Owns request construction (cornerstoneParam envelope, CSRF / cookie /
/// origin / referer headers, percent-encoded form body) for the three
/// `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` endpoints the
/// dashboard exposes. Endpoint URLs and required authentication metadata
/// (sec_token) come from the caller; the client does not own the session
/// itself.
struct QwenCloudTokenPlanAPIClient: Sendable {
    private static let log = CodexBarLog.logger("qwen-cloud")
    struct Context: Sendable {
        let secToken: String
        let secTokenSource: String
        let environment: [String: String]
        let apiCookieHeader: String
        let dashboardURL: URL
    }

    let transport: any ProviderHTTPTransport

    func fetch(
        api: String,
        dataParameters: [String: String],
        context: Context) async throws -> Data
    {
        let url = QwenCloudUsageFetcher.resolveAPIURL(api: api, environment: context.environment)
        guard let host = url.host else {
            throw QwenCloudUsageError.networkError("Invalid quota URL")
        }

        let request = try self.makeRequest(
            api: api,
            dataParameters: dataParameters,
            context: context,
            url: url)
        Self.log.info(
            "Fetching Qwen Cloud token plan API",
            metadata: [
                "api": api,
                "apiHost": host,
                "apiCookieNames": Self.cookieNames(from: context.apiCookieHeader)
                    .joined(separator: ","),
                "hasCSRF": Self.cookieValue(named: "login_aliyunid_csrf", in: context.apiCookieHeader) == nil
                    ? "0" : "1",
                "secTokenSource": context.secTokenSource,
            ])

        let (data, response) = try await self.transport.data(for: request)
        return try Self.processResponse(data: data, response: response)
    }

    func fetchOptional(
        api: String,
        dataParameters: [String: String],
        context: Context) async -> Data?
    {
        do {
            return try await self.fetch(api: api, dataParameters: dataParameters, context: context)
        } catch {
            Self.log.warning(
                "Optional Qwen Cloud token plan metadata fetch failed",
                metadata: ["api": api, "error": error.localizedDescription])
            return nil
        }
    }

    private func makeRequest(
        api: String,
        dataParameters: [String: String],
        context: Context,
        url: URL) throws -> URLRequest
    {
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": context.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": context.dashboardURL.host ?? "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": QwenCloudUsageFetcher.language,
        ]
        if let anonymousID = Self.cookieValue(named: "cna", in: context.apiCookieHeader) {
            cornerstone["X-Anonymous-Id"] = anonymousID
        }
        var apiData = dataParameters as [String: Any]
        apiData["cornerstoneParam"] = cornerstone
        let params: [String: Any] = [
            "Api": api,
            "V": "1.0",
            "Data": apiData,
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            throw QwenCloudUsageError.parseFailed("Could not encode request parameters")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(context.apiCookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            QwenCloudUsageFetcher.gatewayHostBase(environment: context.environment),
            forHTTPHeaderField: "Origin")
        request.setValue(context.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = Self.cookieValue(named: "login_aliyunid_csrf", in: context.apiCookieHeader) ??
            Self.cookieValue(named: "csrf", in: context.apiCookieHeader)
        {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "product", value: QwenCloudUsageFetcher.consoleProduct),
            URLQueryItem(name: "action", value: QwenCloudUsageFetcher.consoleAction),
            URLQueryItem(name: "sec_token", value: context.secToken),
            URLQueryItem(name: "region", value: QwenCloudUsageFetcher.region),
            URLQueryItem(name: "language", value: QwenCloudUsageFetcher.language),
            URLQueryItem(name: "params", value: paramsJSON),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        return request
    }

    private static func processResponse(data: Data, response: URLResponse) throws -> Data {
        if let http = response as? HTTPURLResponse {
            QwenCloudUsageFetcher.log.info(
                "Qwen Cloud HTTP response",
                metadata: [
                    "status": "\(http.statusCode)",
                    "contentType": http.value(forHTTPHeaderField: "Content-Type") ?? "unknown",
                    "bodyBytes": "\(data.count)",
                ])
            switch http.statusCode {
            case 200:
                return data
            case 401, 403:
                throw QwenCloudUsageError.invalidCredentials
            default:
                throw QwenCloudUsageError.apiError("HTTP \(http.statusCode)")
            }
        }
        return data
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        CookieHeaderNormalizer.pairs(from: header)
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
            .value
    }

    private static func cookieNames(from header: String) -> [String] {
        CookieHeaderNormalizer.pairs(from: header)
            .map(\.name)
            .filter { !$0.isEmpty }
            .uniquedSorted()
    }
}
