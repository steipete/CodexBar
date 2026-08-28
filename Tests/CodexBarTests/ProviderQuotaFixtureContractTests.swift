import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderQuotaFixtureContractTests {
    @Test
    func `MiniMax fixture preserves quota windows and plan`() throws {
        let data = try Self.fixtureData(provider: "MiniMax", name: "token-plan-normal", fileExtension: "json")
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(
            data: data,
            now: Date(timeIntervalSince1970: 1_780_282_340))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.identity(for: .minimax)?.loginMethod == "Token Plan Plus")
        #expect(usage.primary?.usedPercent == 4)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_780_297_200))
        #expect(usage.secondary?.usedPercent == 1)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_780_848_000))
    }

    @Test
    func `MiniMax fixture keeps windows when reset timestamps are absent`() throws {
        let data = try Self.fixtureData(
            provider: "MiniMax",
            name: "token-plan-missing-reset",
            fileExtension: "json")
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(
            data: data,
            now: Date(timeIntervalSince1970: 1_780_282_340))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.identity(for: .minimax)?.loginMethod == "Token Plan Plus")
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.usedPercent == 40)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == nil)
    }

    @Test
    func `OpenAI fixture preserves quota windows and plan`() throws {
        let data = try Self.fixtureData(provider: "OpenAI", name: "pro-normal", fileExtension: "html")
        let body = try #require(String(data: data, encoding: .utf8))
        let limits = OpenAIDashboardParser.parseRateLimits(bodyText: body)

        #expect(OpenAIDashboardParser.parsePlanFromHTML(html: body) == "Pro 5x")
        #expect(limits.primary?.usedPercent == 28)
        #expect(limits.primary?.windowMinutes == 300)
        #expect(limits.primary?.resetDescription?.localizedCaseInsensitiveContains("resets") == true)
        #expect(limits.secondary?.usedPercent == 59)
        #expect(limits.secondary?.windowMinutes == 10080)
        #expect(limits.secondary?.resetDescription?.localizedCaseInsensitiveContains("resets") == true)
    }

    @Test
    func `Claude fixture preserves quota windows and plan`() throws {
        let data = try Self.fixtureData(provider: "Claude", name: "weekly-limit", fileExtension: "json")
        let snapshot = try #require(ClaudeUsageFetcher.parse(json: data))

        #expect(snapshot.loginMethod == "Claude Max")
        #expect(snapshot.primary.usedPercent == 7)
        #expect(snapshot.primary.windowMinutes == 300)
        #expect(snapshot.primary.resetDescription?.contains("Europe/Vienna") == true)
        #expect(snapshot.secondary?.usedPercent == 21)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetDescription?.contains("Europe/Vienna") == true)
    }

    private static func fixtureData(provider: String, name: String, fileExtension: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures/Providers/\(provider)"))
        return try Data(contentsOf: url)
    }
}
