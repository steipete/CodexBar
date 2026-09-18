import Foundation
@testable import CodexBarCore

enum OpenRouterReasoningTestSupport {
    static let now = Date(timeIntervalSince1970: 1_787_079_600)
    static let modelName = "example/reasoning-model"
    static let activityBody = #"""
    {"data":[
      {"date":"2026-08-17","model_permaslug":"example/reasoning-model","endpoint_id":"endpoint-a",
       "prompt_tokens":469,"completion_tokens":389,"reasoning_tokens":405,"requests":1,"usage":0.5},
      {"date":"2026-08-17","model_permaslug":"example/reasoning-model","endpoint_id":"endpoint-b",
       "prompt_tokens":31,"completion_tokens":11,"reasoning_tokens":7,"requests":1,"usage":0.25},
      {"date":"2026-08-16","model_permaslug":"example/reasoning-model","endpoint_id":"endpoint-c",
       "prompt_tokens":23,"completion_tokens":0,"reasoning_tokens":29,"requests":1,"usage":0.125}
    ]}
    """#

    static func snapshot(
        engine: ProviderPluginEngineKind = .quickJS,
        activityBody: String = Self.activityBody) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url, url.scheme == "https", url.host == "openrouter.ai",
                  request.httpMethod == "GET"
            else { throw URLError(.unsupportedURL) }
            let body: String
            let key: String
            switch url.path {
            case "/api/v1/credits":
                body = #"{"data":{"total_credits":100,"total_usage":40}}"#
                key = "fixture-key"
            case "/api/v1/key":
                body = #"{"data":{"limit":20,"usage":5}}"#
                key = "fixture-key"
            case "/api/v1/activity":
                body = activityBody
                key = "fixture-management-key"
            default:
                throw URLError(.unsupportedURL)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else {
                throw URLError(.userAuthenticationRequired)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
        return try await BundledPluginTestSupport.runtime("openrouter", engine: engine, transport: transport)
            .fetchUsage(secrets: [
                OpenRouterSettingsReader.envKey: "fixture-key",
                OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "fixture-management-key",
            ], now: Self.now)
    }
}
