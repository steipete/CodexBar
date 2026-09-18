import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct CodexUnlimitedCreditsTests {
    enum Route: CaseIterable {
        case oauth
        case pat
        #if os(macOS)
        case dashboard
        #endif
    }

    private struct Observation {
        let primary: RateWindow?
        let credits: CreditsSnapshot?
        let cost: ProviderCostSnapshot?
    }

    @Test(arguments: Route.allCases, [false, true])
    func `unlimited credits without a finite balance or cap do not create unavailable credits`(
        route: Route,
        hasCredits: Bool) throws
    {
        let result = try self.map(
            route,
            data: self.usageData(hasCredits: hasCredits, unlimited: true))

        #expect(result.primary?.usedPercent == 12)
        #expect(result.primary?.windowMinutes == 300)
        #expect(result.credits == nil)
        #expect(result.cost == nil)
    }

    @Test(arguments: Route.allCases, ["positive balance", "zero balance", "monthly cap"])
    func `unlimited flag preserves independently reported finite balances and monthly caps`(
        route: Route,
        scenario: String) throws
    {
        let balance: Double? = switch scenario {
        case "positive balance": 14
        case "zero balance": 0
        default: nil
        }
        let hasCap = scenario == "monthly cap"
        let result = try self.map(
            route,
            data: self.usageData(hasCredits: true, unlimited: true, balance: balance, hasCap: hasCap))
        let credits = try #require(result.credits)
        let cost = try #require(result.cost)

        #expect(result.primary?.usedPercent == 12)
        #expect(credits.remaining == (balance ?? 0))
        #expect(credits.balanceReadSucceeded == (balance != nil))
        #expect(credits.displayRemaining == (hasCap ? 100 : balance))
        #expect(credits.codexCreditLimit?.remaining == (hasCap ? 100 : nil))
        #expect(cost.balanceIsUnavailable != true)
        #expect(cost.balance == (balance == 14 ? 14 : nil))
        #expect(cost.balanceUpdatedAt == (balance != nil ? credits.updatedAt : nil))
        #expect(cost.limit == (hasCap ? 400 : 0))
    }

    @Test(arguments: Route.allCases)
    func `limited available credits with a missing balance still create an unavailable observation`(
        route: Route) throws
    {
        let result = try self.map(route, data: self.usageData(hasCredits: true, unlimited: false))
        let credits = try #require(result.credits)
        let cost = try #require(result.cost)

        #expect(result.primary?.usedPercent == 12)
        #expect(credits.balanceReadSucceeded == false)
        #expect(credits.creditsAvailable == true)
        #expect(credits.displayRemaining == nil)
        #expect(cost.balanceIsUnavailable == true)
        #expect(cost.balanceUpdatedAt == credits.updatedAt)
        #expect(cost.balance == nil)
    }

    private func usageData(
        hasCredits: Bool,
        unlimited: Bool,
        balance: Double? = nil,
        hasCap: Bool = false) -> Data
    {
        let balanceField = balance.map { ", \"balance\": \($0)" } ?? ""
        let capField = hasCap ? #", "individual_limit": {"limit": 400, "used": 300}"# : ""
        let json = """
        {
          "plan_type": "business",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1700003600,
              "limit_window_seconds": 18000
            }
          },
          "credits": {"has_credits": \(hasCredits), "unlimited": \(unlimited)\(balanceField)}\(capField)
        }
        """
        return Data(json.utf8)
    }

    private func map(_ route: Route, data: Data) throws -> Observation {
        let result: ProviderFetchResult
        switch route {
        case .oauth:
            result = try CodexOAuthFetchStrategy._mapResultForTesting(
                data,
                credentials: CodexOAuthCredentials(
                    accessToken: "fixture-access",
                    refreshToken: "fixture-refresh",
                    idToken: nil,
                    accountId: "fixture-workspace",
                    lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)))
        case .pat:
            result = try CodexPATFetchStrategy._mapResultForTesting(
                data,
                whoami: CodexPATWhoami(
                    accountId: "fixture-workspace",
                    email: "fixture@example.com",
                    planType: "business"))
        #if os(macOS)
        case .dashboard:
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let snapshot = OpenAIDashboardFetcher.snapshotByMergingAPI(
                apiData: OpenAIDashboardFetcher.dashboardAPIData(from: response),
                verifiedEmail: "fixture@example.com",
                previous: nil)
            let credits = snapshot.toCreditsSnapshot()
            return Observation(
                primary: snapshot.primaryLimit,
                credits: credits,
                cost: CodexExtraUsageCost.providerCost(from: credits))
        #endif
        }
        return Observation(primary: result.usage.primary, credits: result.credits, cost: result.usage.providerCost)
    }
}
