#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct OpenAIDashboardIdentityMergeTests {
    @Test(arguments: [nil, "", "other@example.com"] as [String?])
    func `API usage excludes all cached fields from an unpaired identity`(previousEmail: String?) {
        let result = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(),
            verifiedEmail: "owner@example.com",
            previous: self.previous(email: previousEmail))

        #expect(result.signedInEmail == "owner@example.com")
        #expect(result.primaryLimit?.usedPercent == 12)
        #expect(result.accountPlan == "business")
        self.expectNoCachedFields(result)
    }

    @Test(arguments: ["", " \n "])
    func `API merge cannot use a cached email as its verified identity`(verifiedEmail: String) {
        let result = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(),
            verifiedEmail: verifiedEmail,
            previous: self.previous(email: "owner@example.com"))

        #expect(result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        self.expectNoCachedFields(result)
    }

    @Test(arguments: ["different", "missing incoming", "missing previous", "both missing", "blank incoming"])
    func `page merge cannot infer an identity or copy another accounts data`(scenario: String) {
        let currentEmail: String? = switch scenario {
        case "missing incoming", "both missing": nil
        case "blank incoming": " \n "
        default: "owner@example.com"
        }
        let previousEmail: String? = switch scenario {
        case "missing previous", "both missing": nil
        default: "other@example.com"
        }
        let incoming = self.incoming(email: currentEmail)
        let result = OpenAIDashboardFetcher.fillingMissingPageFields(
            incoming,
            from: self.previous(email: previousEmail))

        #expect(result == incoming)
    }

    @Test
    func `normalized matching identities preserve history and independently missing fields`() {
        let previous = self.previous(email: " Owner@Example.COM \n")
        let apiResult = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(),
            verifiedEmail: "owner@example.com",
            previous: previous)
        let pageResult = OpenAIDashboardFetcher.fillingMissingPageFields(
            self.incoming(email: "owner@example.com"),
            from: previous)

        for result in [apiResult, pageResult] {
            #expect(result.signedInEmail == "owner@example.com")
            #expect(result.primaryLimit?.usedPercent == 12)
            #expect(result.creditEvents == previous.creditEvents)
            #expect(result.dailyBreakdown == previous.dailyBreakdown)
            #expect(result.usageBreakdown == previous.usageBreakdown)
            #expect(result.creditsRemaining == 1234)
            #expect(result.balanceIsWorkspace == true)
            #expect(result.codexCreditLimit == previous.codexCreditLimit)
            #expect(result.secondaryLimit == previous.secondaryLimit)
            #expect(result.creditsPurchaseURL == previous.creditsPurchaseURL)
            #expect(result.subscriptionRenewsAt == previous.subscriptionRenewsAt)
        }
        #expect(apiResult.accountPlan == previous.accountPlan)
    }

    @Test(arguments: [nil, "", "other@example.com"] as [String?])
    func `unpaired page identity returns only verified API data`(pageEmail: String?) throws {
        let result = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
            apiData: self.apiData(balance: 14),
            verifiedSignedInEmail: "owner@example.com",
            pageSignedInEmail: pageEmail,
            previous: self.previous(email: "other@example.com"))
        let snapshot = try #require(result)

        #expect(snapshot.signedInEmail == "owner@example.com")
        #expect(snapshot.primaryLimit?.usedPercent == 12)
        #expect(snapshot.creditsRemaining == 14)
        #expect(snapshot.balanceIsWorkspace == true)
        #expect(snapshot.creditEvents.isEmpty)
        #expect(snapshot.dailyBreakdown.isEmpty)
        #expect(snapshot.usageBreakdown.isEmpty)
        #expect(snapshot.accountPlan == "business")
        #expect(snapshot.codeReviewRemainingPercent == nil)
        #expect(snapshot.creditsPurchaseURL == nil)
        #expect(snapshot.codexCreditLimit == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
    }

    @Test
    func `matching page identity allows the normal page merge`() throws {
        let result = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
            apiData: self.apiData(balance: 14),
            verifiedSignedInEmail: " Owner@Example.COM \n",
            pageSignedInEmail: "owner@example.com",
            previous: nil)

        #expect(result == nil)
    }

    @Test(arguments: ["missing API", "missing verification", "blank verification"])
    func `API only fallback requires independently verified API identity`(scenario: String) throws {
        let result = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
            apiData: scenario == "missing API" ? nil : self.apiData(balance: 14),
            verifiedSignedInEmail: scenario == "missing verification" ? nil :
                scenario == "blank verification" ? " \n " : "owner@example.com",
            pageSignedInEmail: "other@example.com",
            previous: self.previous(email: "owner@example.com"))

        #expect(result == nil)
    }

    @Test(arguments: [nil, "other@example.com"] as [String?])
    func `metadata only API cannot be mixed into an unpaired page`(pageEmail: String?) {
        let apiData = OpenAIDashboardFetcher.DashboardAPIData(
            primaryLimit: nil,
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: nil,
            creditsAvailable: false,
            codexCreditLimit: nil,
            accountPlan: "business")
        #expect(!apiData.hasUsageData)
        do {
            _ = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
                apiData: apiData,
                verifiedSignedInEmail: "owner@example.com",
                pageSignedInEmail: pageEmail,
                previous: self.previous(email: "owner@example.com"))
            Issue.record("Unpaired API metadata must not be attributed to the page account")
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(body) {
            #expect(!body.contains("owner@example.com"))
            #expect(!body.contains("other@example.com"))
        } catch {
            Issue.record("Unexpected unpaired-page error: \(error)")
        }
    }

    private func apiData(balance: Double? = nil) -> OpenAIDashboardFetcher.DashboardAPIData {
        OpenAIDashboardFetcher.DashboardAPIData(
            primaryLimit: self.window(used: 12),
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: balance,
            creditsAvailable: balance == nil ? nil : true,
            balanceIsWorkspace: balance == nil ? nil : true,
            codexCreditLimit: nil,
            accountPlan: "business")
    }

    private func incoming(email: String?) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: self.window(used: 12),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    private func previous(email: String?) -> OpenAIDashboardSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let history = OpenAIDashboardDailyBreakdown(
            day: "2023-11-14",
            services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 2)],
            totalCreditsUsed: 2)
        return OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 81,
            codeReviewLimit: self.window(used: 19),
            creditEvents: [CreditEvent(date: date, service: "Codex", creditsUsed: 2)],
            dailyBreakdown: [history],
            usageBreakdown: [history],
            creditsPurchaseURL: "https://chatgpt.com/checkout",
            primaryLimit: self.window(used: 99),
            secondaryLimit: self.window(used: 98),
            creditsRemaining: 1234,
            creditsAvailable: true,
            balanceIsWorkspace: true,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300, limit: 400, remainingPercent: 25, resetsAt: nil, updatedAt: date),
            accountPlan: "Previous plan",
            subscriptionExpiresAt: date.addingTimeInterval(3600),
            subscriptionRenewsAt: date.addingTimeInterval(7200),
            updatedAt: date)
    }

    private func window(used: Double) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }

    private func expectNoCachedFields(_ result: OpenAIDashboardSnapshot) {
        #expect(result.creditEvents.isEmpty)
        #expect(result.dailyBreakdown.isEmpty)
        #expect(result.usageBreakdown.isEmpty)
        #expect(result.codeReviewRemainingPercent == nil)
        #expect(result.codeReviewLimit == nil)
        #expect(result.creditsPurchaseURL == nil)
        #expect(result.secondaryLimit == nil)
        #expect(result.extraRateWindows == nil)
        #expect(result.creditsRemaining == nil)
        #expect(result.creditsAvailable == nil)
        #expect(result.balanceIsWorkspace == nil)
        #expect(result.codexCreditLimit == nil)
        #expect(result.subscriptionExpiresAt == nil)
        #expect(result.subscriptionRenewsAt == nil)
    }
}
#endif
