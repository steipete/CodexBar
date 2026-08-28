import CodexBarCore
import Foundation
import Testing

struct LiteLLMUsageFetcherTests {
    @Test
    func `parses user usage with personal and team budgets`() throws {
        let json = """
        {
          "user_id": "user-123",
          "user_info": {
            "user_id": "user-123",
            "user_alias": "litellm-user@example.com",
            "max_budget": 300.0,
            "spend": 212.3537162499998,
            "user_email": "litellm-user@example.com",
            "budget_reset_at": null,
            "teams": ["team-456"],
            "metadata": {
              "source": "keycloak",
              "preferred_username": "litellm-user@example.com",
              "budget": 300,
              "flags": {
                "keycloak": true
              }
            }
          },
          "keys": [
            {
              "key_name": "sk-...OTHER",
              "user_id": "user-123",
              "team_id": "team-other"
            },
            {
              "key_name": "sk-...IAAw",
              "spend": 212.3537162499998,
              "expires": "2026-09-11T00:12:55.950000+00:00",
              "user_id": "user-123",
              "team_id": "team-456"
            }
          ],
          "teams": [
            {
              "team_alias": "unrelated",
              "team_id": "team-other",
              "max_budget": 5.0,
              "spend": 4.0
            },
            {
              "team_alias": "ai",
              "team_id": "team-456",
              "max_budget": 1000.0,
              "spend": 215.3245658499998,
              "budget_duration": "7d",
              "budget_reset_at": "2026-06-15T00:00:00Z"
            }
          ]
        }
        """

        let parsed = try LiteLLMUsageFetcher._parseUserInfoForTesting(
            Data(json.utf8),
            keyInfo: LiteLLMKeyInfoSnapshot(
                userID: "user-123",
                teamID: "team-456",
                keyName: "sk-...IAAw",
                spendUSD: 212.3537162499998,
                expiresAt: Date(timeIntervalSince1970: 2)),
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(parsed.userID == "user-123")
        #expect(parsed.accountEmail == "litellm-user@example.com")
        #expect(abs(parsed.personalSpendUSD - 212.3537162499998) < 0.000001)
        #expect(parsed.personalBudgetUSD == 300)
        #expect(parsed.teamUsage?.alias == "ai")
        #expect(parsed.teamUsage?.spendUSD == 215.3245658499998)
        #expect(parsed.teamUsage?.budgetUSD == 1000)
        #expect(parsed.keyName == "sk-...IAAw")
        #expect(parsed.keyExpiresAt == Date(timeIntervalSince1970: 2))

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .litellm)
        #expect(snapshot.identity?.accountEmail == "litellm-user@example.com")
        let primary = try #require(snapshot.primary)
        #expect(abs(primary.usedPercent - 70.78457208333327) < 0.000001)
        #expect(primary.resetDescription == "$212.35 / $300.00")
        let secondary = try #require(snapshot.secondary)
        #expect(abs(secondary.usedPercent - 21.53245658499998) < 0.000001)
        #expect(secondary.resetDescription == "Team ai: $215.32 / $1,000.00")
        #expect(snapshot.providerCost?.used == 212.3537162499998)
        #expect(snapshot.providerCost?.limit == 300)
        #expect(snapshot.providerCost?.period == "Personal budget")
    }

    @Test
    func `preserves personal spend when no budget is configured`() throws {
        let json = """
        {
          "user_id": "user-123",
          "user_info": {
            "user_id": "user-123",
            "max_budget": null,
            "spend": 12.5
          }
        }
        """

        let parsed = try LiteLLMUsageFetcher._parseUserInfoForTesting(
            Data(json.utf8),
            keyInfo: LiteLLMKeyInfoSnapshot(
                userID: "user-123",
                teamID: nil,
                keyName: "personal-key",
                spendUSD: 12.5,
                expiresAt: nil),
            updatedAt: Date(timeIntervalSince1970: 1))

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Personal spend")
    }

    @Test
    func `parses key info identity for user lookup`() throws {
        let json = """
        {
          "key": "sk-redacted",
          "info": {
            "key_name": "sk-...IAAw",
            "spend": 212.3537162499998,
            "expires": "2026-09-11T00:12:55.950000+00:00",
            "user_id": "user-123",
            "team_id": "team-456",
            "max_budget": null
          }
        }
        """

        let parsed = try LiteLLMUsageFetcher._parseKeyInfoForTesting(Data(json.utf8))

        #expect(parsed.userID == "user-123")
        #expect(parsed.teamID == "team-456")
        #expect(parsed.keyName == "sk-...IAAw")
        #expect(parsed.spendUSD == 212.3537162499998)
    }

    @Test
    func `parses team-only key info without user identity`() throws {
        let json = """
        {
          "info": {
            "key_name": "team-service-key",
            "spend": 25.0,
            "team_id": "team-456"
          }
        }
        """

        let parsed = try LiteLLMUsageFetcher._parseKeyInfoForTesting(Data(json.utf8))

        #expect(parsed.userID == nil)
        #expect(parsed.teamID == "team-456")
        #expect(parsed.keyName == "team-service-key")
    }

    @Test
    func `management urls accept root or v1 base urls`() throws {
        let root = try #require(URL(string: "https://litellm.example.com"))
        let versioned = try #require(URL(string: "https://litellm.example.com/v1"))
        let nestedVersioned = try #require(URL(string: "https://gateway.example.com/litellm/v1/"))

        #expect(
            LiteLLMUsageFetcher
                ._keyInfoURLForTesting(baseURL: root)
                .absoluteString == "https://litellm.example.com/key/info")
        #expect(
            LiteLLMUsageFetcher
                ._keyInfoURLForTesting(baseURL: versioned)
                .absoluteString == "https://litellm.example.com/key/info")
        #expect(
            LiteLLMUsageFetcher
                ._userInfoURLForTesting(baseURL: nestedVersioned, userID: "user-123")
                .absoluteString == "https://gateway.example.com/litellm/user/info?user_id=user-123")
        #expect(
            LiteLLMUsageFetcher
                ._teamInfoURLForTesting(baseURL: nestedVersioned, teamID: "team-456")
                .absoluteString == "https://gateway.example.com/litellm/team/info?team_id=team-456")
    }

    @Test
    func `settings reader trims quoted environment values`() {
        let environment = [
            "LITELLM_API_KEY": " 'sk-test' ",
            "LITELLM_BASE_URL": #" "https://litellm.example.com/v1" "#,
        ]

        #expect(LiteLLMSettingsReader.apiKey(environment: environment) == "sk-test")
        #expect(LiteLLMSettingsReader.baseURL(environment: environment)?
            .absoluteString == "https://litellm.example.com/v1")
    }

    @Test
    func `fetch trims api key before sending management requests`() async throws {
        let baseURL = try #require(URL(string: "https://litellm.example.com/v1"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

            let path = request.url?.path
            let query = request.url?.query
            let body: String
            switch path {
            case "/key/info":
                #expect(query == nil)
                body = """
                {
                  "info": {
                    "user_id": "user-123",
                    "team_id": "team-456",
                    "spend": 1
                  }
                }
                """
            case "/user/info":
                #expect(query == "user_id=user-123")
                body = """
                {
                  "user_id": "user-123",
                  "user_info": {
                    "user_id": "user-123",
                    "max_budget": 10,
                    "spend": 1
                  }
                }
                """
            default:
                Issue.record("unexpected LiteLLM request path: \(path ?? "nil")")
                body = "{}"
            }

            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(body.utf8), response)
        }

        let snapshot = try await LiteLLMUsageFetcher.fetchUsage(
            apiKey: " sk-test\n",
            baseURL: baseURL,
            transport: transport)

        #expect(snapshot.userID == "user-123")
        let requests = await transport.requests()
        #expect(requests.count == 2)
    }

    @Test
    func `fetches team usage for team-only virtual keys`() async throws {
        let baseURL = try #require(URL(string: "https://litellm.example.com/v1"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-team")

            let path = request.url?.path
            let query = request.url?.query
            let body: String
            switch path {
            case "/key/info":
                #expect(query == nil)
                body = """
                {
                  "info": {
                    "key_name": "team-service-key",
                    "team_id": "team-456",
                    "spend": 25
                  }
                }
                """
            case "/team/info":
                #expect(query == "team_id=team-456")
                body = """
                {
                  "team_id": "team-456",
                  "team_info": {
                    "team_id": "team-456",
                    "team_alias": "platform",
                    "max_budget": 100,
                    "spend": 25,
                    "budget_duration": "30d",
                    "budget_reset_at": "2026-07-01T00:00:00Z"
                  }
                }
                """
            default:
                Issue.record("unexpected LiteLLM request path: \(path ?? "nil")")
                body = "{}"
            }

            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(body.utf8), response)
        }

        let snapshot = try await LiteLLMUsageFetcher.fetchUsage(
            apiKey: "sk-team",
            baseURL: baseURL,
            transport: transport,
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(snapshot.userID == nil)
        #expect(snapshot.teamUsage?.id == "team-456")
        #expect(snapshot.teamUsage?.alias == "platform")
        #expect(snapshot.teamUsage?.spendUSD == 25)
        #expect(snapshot.teamUsage?.budgetUSD == 100)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.providerCost?.used == 25)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.providerCost?.period == "Team budget")

        let requests = await transport.requests()
        #expect(requests.count == 2)
    }

    @Test
    func `fetch surfaces rejected virtual key`() async throws {
        let baseURL = try #require(URL(string: "https://litellm.example.com"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-target")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"detail":"Unauthorized"}"#.utf8), response)
        }

        do {
            _ = try await LiteLLMUsageFetcher.fetchUsage(
                apiKey: "sk-target",
                baseURL: baseURL,
                transport: transport)
            Issue.record("expected LiteLLMUsageError.apiError")
        } catch let LiteLLMUsageError.apiError(message) {
            #expect(message.contains("HTTP 401"))
            #expect(message.contains("Unauthorized"))
        } catch {
            Issue.record("expected LiteLLMUsageError.apiError, got \(error)")
        }

        let requests = await transport.requests()
        #expect(requests.count == 1)
    }
}
