// Offline CLI harness: run the shipped provider runtime against synthetic HTTP replies.
import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct OllamaBalanceProof {
    static func main() async throws {
        let fixtures = [
            (
                "monthly",
                #"{"included":{"balance_usd":"75","allowance_usd":100,"period":{"until":"2026-12-01T00:00:00Z"}},"purchased":{"balance_usd":"12.50"}}"#),
            (
                "legacy",
                #"{"included":{"session":{"remaining_percent":75,"resets_at":"2026-12-01T07:00:00Z"},"weekly":{"remaining_percent":40,"resets_at":"2026-12-05T00:00:00Z"}},"purchased":{"balance_usd":25}}"#),
            ("zero-allowance", #"{"included":{"balance_usd":0,"allowance_usd":0}}"#),
        ]
        for (name, body) in fixtures {
            let transport = ProviderHTTPTransportHandler { request in
                precondition(request.url?.absoluteString == "https://ollama.com/api/balance")
                precondition(request.httpMethod == "GET")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(body.utf8), response)
            }
            let runtime = try ProviderPluginRuntime(bundledPlugin: "ollama-api", transport: transport)
            let usage = try await runtime.fetchUsage(
                secrets: ["OLLAMA_API_KEY": "fixture-key"],
                now: Date(timeIntervalSince1970: 1_800_000_000))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try print("\(name): \(String(decoding: encoder.encode(usage), as: UTF8.self))")
        }
    }
}
