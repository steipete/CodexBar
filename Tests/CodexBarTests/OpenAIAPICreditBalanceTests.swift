import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIAPICreditBalanceTests {
    private func makeContext(
        apiKey: String = "sk-test",
        usesAdminKey: Bool = false,
        projectID: String? = nil,
        selectedTokenAccountID: UUID? = nil,
        historyDays: Int = 30) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let apiKeyEnvironmentKey = usesAdminKey
            ? OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey
            : OpenAIAPISettingsReader.apiKeyEnvironmentKey
        var env = [apiKeyEnvironmentKey: apiKey]
        if let projectID {
            env[OpenAIAPISettingsReader.projectIDEnvironmentKey] = projectID
        }
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: selectedTokenAccountID,
            costUsageHistoryDays: historyDays)
    }

    @Test
    func `prefers admin key environment variable`() {
        let token = OpenAIAPISettingsReader.apiKey(environment: [
            "OPENAI_API_KEY": "sk-project",
            "OPENAI_ADMIN_KEY": "sk-admin",
        ])

        #expect(token == "sk-admin")
    }

    @Test
    func `parses credit grants balance`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "object": "credit_summary",
          "total_granted": 25.5,
          "total_used": 7.25,
          "total_available": 18.25,
          "grants": {
            "object": "list",
            "data": [
              {
                "grant_amount": 10.0,
                "used_amount": 1.0,
                "effective_at": 1690000000,
                "expires_at": 1800000000
              }
            ]
          }
        }
        """

        let snapshot = try OpenAIAPICreditBalanceFetcher._parseSnapshotForTesting(Data(json.utf8), now: now)

        #expect(snapshot.totalGranted == 25.5)
        #expect(snapshot.totalUsed == 7.25)
        #expect(snapshot.totalAvailable == 18.25)
        #expect(snapshot.nextGrantExpiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test
    func `maps balance to usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let balance = OpenAIAPICreditBalanceSnapshot(
            totalGranted: 100,
            totalUsed: 40,
            totalAvailable: 60,
            nextGrantExpiry: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: now)

        let usage = balance.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.resetDescription == "$60.00 available")
        #expect(usage.providerCost?.used == 40)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.identity?.providerID == .openai)
        #expect(usage.identity?.loginMethod == "API balance: $60.00")
    }

    @Test
    func `falls back to legacy billing when admin usage rejects credentials`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { _, _ in
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 403)
            },
            balanceFetcher: { _ in
                OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext())

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.identity?.loginMethod == "API balance: $75.00")
    }

    @Test
    func `legacy API key without project ID falls back to legacy billing`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == nil)
                #expect(historyDays == 30)
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 403)
            },
            balanceFetcher: { apiKey in
                #expect(apiKey == "sk-test")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext())

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.identity?.loginMethod == "API balance: $75.00")
        #expect(result.usage.identity?.accountOrganization == nil)
    }

    @Test
    func `selected token account uses scrubbed final environment for legacy fallback`() async throws {
        let accountID = UUID()
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "account-token")
                #expect(credential.projectID == nil)
                #expect(historyDays == 30)
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 403)
            },
            balanceFetcher: { apiKey in
                #expect(apiKey == "account-token")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext(
            apiKey: "account-token",
            usesAdminKey: true,
            selectedTokenAccountID: accountID))

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.identity?.loginMethod == "API balance: $75.00")
        #expect(result.usage.identity?.accountOrganization == nil)
    }

    @Test
    func `preserves admin usage error when legacy fallback also fails`() async {
        let usageFailure = OpenAIAPIUsageError.parseFailed(endpoint: "costs", message: "changed")
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { _, _ in throw usageFailure },
            balanceFetcher: { _ in throw OpenAIAPICreditBalanceError.forbidden })

        do {
            _ = try await strategy.fetch(self.makeContext())
            Issue.record("Expected admin usage failure")
        } catch let error as OpenAIAPIUsageError {
            #expect(error == usageFailure)
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error)")
        }
    }

    @Test
    func `falls back to credit balance when admin usage endpoint is unavailable`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == nil)
                #expect(historyDays == 90)
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 500)
            },
            balanceFetcher: { apiKey in
                #expect(apiKey == "sk-test")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext(historyDays: 90))

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.providerCost?.used == 25)
        #expect(result.usage.providerCost?.limit == 100)
    }
}
