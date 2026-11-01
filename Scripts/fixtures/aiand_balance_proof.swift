// Offline CLI harness: production plugin runtime, synthetic HTTP replies, no account access.
import CodexBarCore
import Foundation

@main
struct AiAndBalanceProof {
    static func main() async throws {
        for (name, wallet, status) in [
            ("usd", #"{"balance":"42.75000000","currency":"usd"}"#, 200),
            ("jpy", #"{"balance":"123.45678901","currency":"jpy"}"#, 200),
            ("negative", #"{"balance":"-0.00000001","currency":"usd"}"#, 200),
            ("unavailable", "redacted-error", 403),
        ] {
            let transport = ProviderHTTPTransportHandler { request in
                precondition(request.url?.host == "api.aiand.com")
                precondition(request.httpMethod == "GET")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let balance = request.url?.path == "/billing/balance"
                precondition(balance || request.url?.path == "/logs")
                let body = balance ? wallet : #"{"data":[{"cost":"2.50000000","currency":"usd"}],"has_more":false}"#
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: balance ? status : 200,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(body.utf8), response)
            }
            let runtime = try ProviderPluginRuntime(bundledPlugin: "aiand", transport: transport)
            let usage = try await runtime.fetchUsage(
                secrets: ["AIAND_API_KEY": "fixture-key"],
                now: Date(timeIntervalSince1970: 1_800_000_000))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try print("\(name): \(String(decoding: encoder.encode(usage), as: UTF8.self))")
        }
    }
}
