import Foundation
import Testing
@testable import CodexBarCore

enum NeuralWattPluginTestSupport {
    static func fetch(_ data: Data, now: Date) async throws -> UsageSnapshot {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "neuralwatt",
            transport: ProviderHTTPTransportHandler { request in
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (data, response)
            })
        return try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.neuralwatt.test"],
            secrets: ["NEURALWATT_API_KEY": "fixture-key"],
            now: now)
    }
}
