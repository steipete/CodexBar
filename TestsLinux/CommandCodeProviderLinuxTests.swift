import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CommandCodeProviderLinuxTests {
    private static let creditsJSON = #"""
    {
      "credits": {
        "monthlyCredits": 9.15,
        "purchasedCredits": 0,
        "premiumMonthlyCredits": 0,
        "opensourceMonthlyCredits": 0
      },
      "windowLimits": {
        "fiveHour": {"cap": 3, "used": 0.75, "resetAt": 1780000000000},
        "weekly": {"cap": 6, "used": 1.5, "resetAt": 1780100000000}
      }
    }
    """#

    private static let subscriptionJSON = #"""
    {
      "success": true,
      "data": {
        "status": "active",
        "planId": "individual-go",
        "currentPeriodEnd": "2026-08-23T18:08:48.000Z"
      }
    }
    """#

    @Test
    func `registers rolling and monthly quota lanes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .commandcode)

        #expect(descriptor.metadata.sessionLabel == "5-hour")
        #expect(descriptor.metadata.weeklyLabel == "Weekly")
        #expect(descriptor.metadata.opusLabel == "Monthly")
        #expect(descriptor.metadata.supportsOpus)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .web])
    }

    @Test
    func `loads API key from environment and Command Code auth file`() throws {
        #expect(CommandCodeAPIKeyReader.apiKey(environment: [
            "COMMAND_CODE_API_KEY": " environment-key ",
        ]) == "environment-key")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFile = CommandCodeAPIKeyReader.defaultAuthFileURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: authFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"apiKey":"file-key"}"#.utf8).write(to: authFile)

        #expect(CommandCodeAPIKeyReader.apiKey(environment: ["HOME": home.path]) == "file-key")
    }

    @Test
    func `fetches API key usage from alpha billing endpoints`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let path = try #require(request.url?.path)
            #expect(path == "/alpha/billing/credits" || path == "/alpha/billing/subscriptions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer api-test")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "api-test")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            let body = path.hasSuffix("/credits") ? Self.creditsJSON : Self.subscriptionJSON
            return try Self.response(for: request, body: body)
        }

        let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
            apiKey: "api-test",
            session: transport,
            now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_780_100_000))
        #expect(abs((usage.tertiary?.usedPercent ?? -1) - 8.5) < 0.0001)
        #expect(usage.tertiary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.tertiary?.resetsAt == Self.date("2026-08-23T18:08:48.000Z"))
        #expect(usage.identity?.loginMethod == "Go · $0.85 of $10.00")
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 123))
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private static func response(
        for request: URLRequest,
        body: String,
        statusCode: Int = 200) throws -> (Data, URLResponse)
    {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"])
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }
}
