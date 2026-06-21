import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderQuotaFixtureContractTests {
    private struct ProviderFixtureCase: Sendable {
        let provider: UsageProvider
        let fixtureName: String
        let fixtureExtension: String
        let parser: Parser
        let expectedPlan: String?
        let expectedPrimary: ExpectedWindow
        let expectedSecondary: ExpectedWindow

        var displayName: String {
            "\(self.provider.rawValue)/\(self.fixtureName).\(self.fixtureExtension)"
        }

        var providerDirectory: String {
            switch self.provider {
            case .minimax:
                "MiniMax"
            case .openai:
                "OpenAI"
            case .claude:
                "Claude"
            default:
                self.provider.rawValue
            }
        }
    }

    private enum Parser: Sendable {
        case minimaxCodingPlanRemains(now: Date)
        case openAIWebDashboard
        case claudeCLIUsage
    }

    private struct ParsedFixture: Sendable {
        let plan: String?
        let primary: RateWindow?
        let secondary: RateWindow?
    }

    private struct ExpectedWindow: Equatable, Sendable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetDescriptionContains: String?
        let resetsAt: Date?
        let resetAbsent: Bool

        static let absent = ExpectedWindow(
            usedPercent: nil,
            windowMinutes: nil,
            resetDescriptionContains: nil,
            resetsAt: nil,
            resetAbsent: false)
    }

    @Test
    func `provider quota fixtures satisfy parsing contract`() throws {
        for fixtureCase in Self.fixtureCases {
            let parsed = try Self.parse(fixtureCase)

            #expect(parsed.plan == fixtureCase.expectedPlan, "\(fixtureCase.displayName) plan")
            try Self.expectWindow(
                parsed.primary,
                expected: fixtureCase.expectedPrimary,
                fixtureName: "\(fixtureCase.displayName) primary")
            try Self.expectWindow(
                parsed.secondary,
                expected: fixtureCase.expectedSecondary,
                fixtureName: "\(fixtureCase.displayName) secondary")
        }
    }

    private static let fixtureCases: [ProviderFixtureCase] = [
        ProviderFixtureCase(
            provider: .minimax,
            fixtureName: "token-plan-normal",
            fixtureExtension: "json",
            parser: .minimaxCodingPlanRemains(now: Date(timeIntervalSince1970: 1_780_282_340)),
            expectedPlan: "Token Plan Plus",
            expectedPrimary: ExpectedWindow(
                usedPercent: 4,
                windowMinutes: 300,
                resetDescriptionContains: nil,
                resetsAt: Date(timeIntervalSince1970: 1_780_297_200),
                resetAbsent: false),
            expectedSecondary: ExpectedWindow(
                usedPercent: 1,
                windowMinutes: 10080,
                resetDescriptionContains: nil,
                resetsAt: Date(timeIntervalSince1970: 1_780_848_000),
                resetAbsent: false)),
        ProviderFixtureCase(
            provider: .minimax,
            fixtureName: "token-plan-missing-reset",
            fixtureExtension: "json",
            parser: .minimaxCodingPlanRemains(now: Date(timeIntervalSince1970: 1_780_282_340)),
            expectedPlan: "Token Plan Plus",
            expectedPrimary: ExpectedWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetDescriptionContains: nil,
                resetsAt: nil,
                resetAbsent: true),
            expectedSecondary: ExpectedWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetDescriptionContains: nil,
                resetsAt: nil,
                resetAbsent: true)),
        ProviderFixtureCase(
            provider: .openai,
            fixtureName: "pro-normal",
            fixtureExtension: "html",
            parser: .openAIWebDashboard,
            expectedPlan: "Pro 5x",
            expectedPrimary: ExpectedWindow(
                usedPercent: 28,
                windowMinutes: 300,
                resetDescriptionContains: "resets",
                resetsAt: nil,
                resetAbsent: false),
            expectedSecondary: ExpectedWindow(
                usedPercent: 59,
                windowMinutes: 10080,
                resetDescriptionContains: nil,
                resetsAt: nil,
                resetAbsent: false)),
        ProviderFixtureCase(
            provider: .claude,
            fixtureName: "weekly-limit",
            fixtureExtension: "json",
            parser: .claudeCLIUsage,
            expectedPlan: "Claude Max",
            expectedPrimary: ExpectedWindow(
                usedPercent: 7,
                windowMinutes: 300,
                resetDescriptionContains: "Europe/Vienna",
                resetsAt: nil,
                resetAbsent: false),
            expectedSecondary: ExpectedWindow(
                usedPercent: 21,
                windowMinutes: 10080,
                resetDescriptionContains: "Europe/Vienna",
                resetsAt: nil,
                resetAbsent: false)),
    ]

    private static func parse(_ fixtureCase: ProviderFixtureCase) throws -> ParsedFixture {
        let data = try self.fixtureData(for: fixtureCase)

        switch fixtureCase.parser {
        case let .minimaxCodingPlanRemains(now):
            let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
            let usage = snapshot.toUsageSnapshot()
            return ParsedFixture(
                plan: usage.identity(for: .minimax)?.loginMethod,
                primary: usage.primary,
                secondary: usage.secondary)

        case .openAIWebDashboard:
            let bodyText = try #require(String(data: data, encoding: .utf8))
            let limits = OpenAIDashboardParser.parseRateLimits(bodyText: bodyText)
            return ParsedFixture(
                plan: OpenAIDashboardParser.parsePlanFromHTML(html: bodyText),
                primary: limits.primary,
                secondary: limits.secondary)

        case .claudeCLIUsage:
            let snapshot = try #require(ClaudeUsageFetcher.parse(json: data))
            return ParsedFixture(
                plan: snapshot.loginMethod,
                primary: snapshot.primary,
                secondary: snapshot.secondary)
        }
    }

    private static func fixtureData(for fixtureCase: ProviderFixtureCase) throws -> Data {
        let subdirectory = "Fixtures/Providers/\(fixtureCase.providerDirectory)"
        let url = try #require(Bundle.module.url(
            forResource: fixtureCase.fixtureName,
            withExtension: fixtureCase.fixtureExtension,
            subdirectory: subdirectory))
        return try Data(contentsOf: url)
    }

    private static func expectWindow(
        _ window: RateWindow?,
        expected: ExpectedWindow,
        fixtureName: String) throws
    {
        if expected == .absent {
            #expect(window == nil, "\(fixtureName) should be absent")
            return
        }

        let window = try #require(window, "\(fixtureName) should be present")
        #expect(window.usedPercent == expected.usedPercent, "\(fixtureName) usedPercent")
        #expect(window.windowMinutes == expected.windowMinutes, "\(fixtureName) windowMinutes")
        if let resetDescriptionContains = expected.resetDescriptionContains {
            #expect(
                window.resetDescription?.localizedCaseInsensitiveContains(resetDescriptionContains) == true,
                "\(fixtureName) resetDescription")
        }
        if expected.resetAbsent {
            #expect(window.resetsAt == nil, "\(fixtureName) resetsAt should be absent")
        } else if let resetsAt = expected.resetsAt {
            #expect(window.resetsAt == resetsAt, "\(fixtureName) resetsAt")
        }
    }
}
