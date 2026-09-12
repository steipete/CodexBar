#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct OpenAIDashboardIdentityMergeTests {
    @Test(arguments: [nil, "", "workspace-a"] as [String?])
    func `legacy personal dashboard fields survive page and API refreshes without account IDs`(accountID: String?) {
        for workspace in [nil, false] as [Bool?] {
            let previous = self.previous(email: "owner@example.com", accountID: accountID, workspace: workspace)
            let api = OpenAIDashboardFetcher.snapshotByMergingAPI(
                apiData: self.apiData(), verifiedEmail: "owner@example.com", previous: previous)
            let page = OpenAIDashboardFetcher.fillingMissingPageFields(
                self.incoming(email: "owner@example.com", accountID: nil), from: previous)
            for result in [api, page] {
                #expect(result.creditsRemaining == previous.creditsRemaining)
                #expect(result.creditEvents == previous.creditEvents)
                #expect(result.dailyBreakdown == previous.dailyBreakdown)
                #expect(result.usageBreakdown == previous.usageBreakdown)
                #expect(result.codexCreditLimit == previous.codexCreditLimit)
                #expect(result.secondaryLimit == previous.secondaryLimit)
                #expect(result.subscriptionExpiresAt == previous.subscriptionExpiresAt)
                #expect(result.subscriptionRenewsAt == previous.subscriptionRenewsAt)
                #expect(!result.requiresWorkspaceBalanceScope)
            }
        }
    }

    @Test(arguments: [nil, "", " \n "] as [String?])
    func `unidentified page waits without inheriting the API identity`(pageEmail: String?) {
        #expect(OpenAIDashboardFetcher.shouldWaitForPageIdentity(
            verifiedSignedInEmail: "owner@example.com", pageSignedInEmail: pageEmail))
        #expect(!OpenAIDashboardFetcher.shouldWaitForPageIdentity(
            verifiedSignedInEmail: "owner@example.com", pageSignedInEmail: "other@example.com"))
    }

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
        let previous = self.previous(email: " Owner@Example.COM \n").withSubscriptionMetadata(nil)
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
    func `missing page identity waits and mismatched page returns verified API data`(pageEmail: String?) throws {
        let result = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
            apiData: self.apiData(balance: 14),
            verifiedSignedInEmail: "owner@example.com",
            pageSignedInEmail: pageEmail,
            previous: self.previous(email: "other@example.com"))
        if pageEmail?.isEmpty != false {
            #expect(result == nil)
            return
        }
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
            let result = try OpenAIDashboardFetcher.snapshotForUnpairedPage(
                apiData: apiData,
                verifiedSignedInEmail: "owner@example.com",
                pageSignedInEmail: pageEmail,
                previous: self.previous(email: "owner@example.com"))
            if pageEmail == nil {
                #expect(result == nil)
            } else {
                Issue.record("Unpaired API metadata must not be attributed to the page account")
            }
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(body) {
            #expect(!body.contains("owner@example.com"))
            #expect(!body.contains("other@example.com"))
        } catch {
            Issue.record("Unexpected unpaired-page error: \(error)")
        }
    }

    private func apiData(balance: Double? = nil) -> OpenAIDashboardFetcher.DashboardAPIData {
        OpenAIDashboardFetcher.DashboardAPIData(
            accountID: "workspace-a",
            primaryLimit: self.window(used: 12),
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: balance,
            creditsAvailable: balance == nil ? nil : true,
            balanceIsWorkspace: balance == nil ? nil : true,
            codexCreditLimit: nil,
            accountPlan: "business")
    }

    private func incoming(email: String?, accountID: String? = "workspace-a") -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            accountID: accountID,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: self.window(used: 12),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    private func previous(
        email: String?, accountID: String? = "workspace-a", workspace: Bool? = true) -> OpenAIDashboardSnapshot
    {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let history = OpenAIDashboardDailyBreakdown(
            day: "2023-11-14",
            services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 2)],
            totalCreditsUsed: 2)
        return OpenAIDashboardSnapshot(
            signedInEmail: email,
            accountID: accountID,
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
            balanceIsWorkspace: workspace,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300, limit: 400, remainingPercent: 25, resetsAt: nil, updatedAt: date),
            accountPlan: "Previous plan",
            subscriptionExpiresAt: date.addingTimeInterval(3600),
            subscriptionRenewsAt: date.addingTimeInterval(7200),
            updatedAt: date)
    }

    @Test(arguments: [nil, "", "workspace-b"] as [String?])
    func `matching email cannot reuse another or unknown workspace`(accountID: String?) throws {
        let previous = self.previous(email: "owner@example.com", accountID: accountID)
        let persisted = try JSONDecoder().decode(
            OpenAIDashboardSnapshot.self, from: JSONEncoder().encode(previous.withSubscriptionMetadata(nil)))
        let result = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(), verifiedEmail: "owner@example.com", previous: persisted)
        self.expectNoCachedFields(result)
        #expect(result.accountID == "workspace-a")
        let incoming = self.incoming(email: "owner@example.com")
        #expect(OpenAIDashboardFetcher.fillingMissingPageFields(incoming, from: persisted) == incoming)
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
