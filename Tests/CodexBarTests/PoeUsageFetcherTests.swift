import Foundation
import Testing
@testable import CodexBarCore

struct PoePluginGoldenTests {
    @Test(arguments: ["1500", "\"2500\""])
    func `balance fixtures map to identity without rate windows`(_ rawBalance: String) async throws {
        let snapshot = try await Self.fetch(balance: #"{"current_point_balance": \#(rawBalance)}"#)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.identity?.providerID == .poe)
        #expect(snapshot.identity?.loginMethod == "Balance: \(rawBalance == "1500" ? "1,500" : "2,500") points")
    }

    @Test
    func `absent balance produces an empty identity`() async throws {
        let snapshot = try await Self.fetch(balance: "{}")

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.providerID == .poe)
        #expect(snapshot.identity?.loginMethod == nil)
    }

    @Test
    func `malformed balance fixture fails the JS contract`() async throws {
        await #expect(throws: ProviderPluginError.self) {
            _ = try await Self.fetch(balance: "not-json")
        }
    }

    @Test
    func `history failure preserves the required balance result`() async throws {
        let snapshot = try await Self.fetch(
            balance: #"{"current_point_balance":1500}"#,
            historyStatus: 500)

        #expect(snapshot.identity?.loginMethod == "Balance: 1,500 points")
        #expect(try snapshot.details == [ProviderDetailSection(
            title: "Points",
            rows: [.init(label: "Current balance", value: "1,500 points")])])
    }

    private static func fetch(balance: String, historyStatus: Int = 200) async throws -> UsageSnapshot {
        let transport = ProviderHTTPTransportHandler { request in
            let isHistory = request.url?.path == "/usage/points_history"
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: isHistory ? historyStatus : 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            let body = isHistory ? #"{"data":[],"next_cursor":null}"# : balance
            return (Data(body.utf8), response)
        }
        return try await ProviderPluginRuntime(bundledPlugin: "poe", transport: transport)
            .fetchUsage(secrets: ["POE_API_KEY": "test-key"])
    }
}
