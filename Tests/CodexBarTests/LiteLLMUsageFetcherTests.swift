import Foundation
import Testing
@testable import CodexBarCore

struct LiteLLMUsageFetcherTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `parses user usage with personal and team budgets`(engine: ProviderPluginEngineKind) async throws {
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

        let snapshot = try await LiteLLMPluginTestSupport.fetch(json, engine: engine)
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

    @Test(arguments: BundledPluginTestSupport.engines)
    func `preserves personal spend when no budget is configured`(engine: ProviderPluginEngineKind) async throws {
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

        let snapshot = try await LiteLLMPluginTestSupport.fetch(json, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Personal spend")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `parses key info identity for user lookup`(engine: ProviderPluginEngineKind) async throws {
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

        let snapshot = try await LiteLLMPluginTestSupport.fetch(
            #"{"user_info":{}}"#, key: json, engine: engine)
        #expect(snapshot.subscriptionExpiresAt == ISO8601DateParser.parse("2026-09-11T00:12:55.950000+00:00"))
        #expect(snapshot.identity?.loginMethod == "api")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `parses team-only key info without user identity`(engine: ProviderPluginEngineKind) async throws {
        let json = """
        {
          "info": {
            "key_name": "team-service-key",
            "spend": 25.0,
            "team_id": "team-456"
          }
        }
        """

        let snapshot = try await LiteLLMPluginTestSupport.fetch(
            #"{"team_info":{"team_id":"team-456","spend":25}}"#, key: json, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.period == "Team spend")
        #expect(snapshot.providerCost?.used == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `management urls accept root or v1 base urls`(engine: ProviderPluginEngineKind) async throws {
        for base in [
            "https://proxy.example.com",
            "https://proxy.example.com/v1",
            "https://proxy.example.com/litellm/v1/",
            "http://proxy.local/v1",
            "http://192.168.1.2:4000/v1",
            "http://[fd00::1]:4000/v1",
        ] {
            let transport = ProviderHTTPTransportHandler { request in
                let prefix = base.contains("/litellm/") ? "/litellm" : ""
                let isKey = request.url?.path == "\(prefix)/key/info"
                #expect(request.url?.path == "\(prefix)/\(isKey ? "key" : "user")/info")
                #expect(request.url?.query == (isKey ? nil : "user_id=user-123"))
                let body = isKey ? #"{"info":{"user_id":"user-123"}}"# : #"{"user_info":{}}"#
                return (Data(body.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            _ = try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
                .fetchUsage(settings: ["LITELLM_BASE_URL": base], secrets: ["LITELLM_API_KEY": "fixture-key"])
        }
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

    @Test(arguments: BundledPluginTestSupport.engines)
    func `fetch trims api key before sending management requests`(engine: ProviderPluginEngineKind) async throws {
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

        let snapshot = try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
            .fetchUsage(
                settings: ["LITELLM_BASE_URL": baseURL.absoluteString],
                secrets: ["LITELLM_API_KEY": " sk-test\n"])

        #expect(snapshot.primary?.usedPercent == 10)
        let requests = await transport.requests()
        #expect(requests.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `fetches team usage for team-only virtual keys`(engine: ProviderPluginEngineKind) async throws {
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

        let snapshot = try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
            .fetchUsage(
                settings: ["LITELLM_BASE_URL": baseURL.absoluteString],
                secrets: ["LITELLM_API_KEY": "sk-team"],
                now: Date(timeIntervalSince1970: 1))

        #expect(snapshot.identity?.accountOrganization == "platform")
        let usage = snapshot
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.providerCost?.used == 25)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.providerCost?.period == "Team budget")

        let requests = await transport.requests()
        #expect(requests.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejects mismatched identities and malformed budget payloads`(engine: ProviderPluginEngineKind) async throws {
        for (key, body) in [
            (#"{"info":{}}"#, #"{"user_info":{}}"#),
            (#"{"info":{"user_id":"expected"}}"#, #"{"user_info":{"user_id":"other"}}"#),
            (#"{"info":{"team_id":"expected"}}"#, #"{"team_info":{"team_id":"other"}}"#),
            (#"{"info":{"user_id":"expected"}}"#, #"{"user_info":{"spend":"4"}}"#),
            (#"{"info":{"user_id":"expected"}}"#, #"{"user_info":{},"teams":[{}]}"#),
            (#"{"info":{"user_id":"expected"}}"#, #"{"user_info":{},"teams":{}}"#),
        ] {
            do {
                _ = try await LiteLLMPluginTestSupport.fetch(body, key: key, engine: engine)
                Issue.record("Expected parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero spend keeps API identity and never selects another team`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await LiteLLMPluginTestSupport.fetch(#"""
        {"user_info":{"user_alias":"   ","metadata":{"preferred_username":" synthetic-user "}},
         "teams":[{"team_id":"unrelated","team_alias":"Other","spend":5,"max_budget":10}]}
        """#, engine: engine)
        #expect(usage.primary == nil && usage.secondary == nil && usage.providerCost == nil)
        #expect(usage.identity?.accountOrganization == nil)
        #expect(usage.identity?.accountEmail == "synthetic-user")
        #expect(usage.identity?.loginMethod == "api")
        let malformedMetadata = try await LiteLLMPluginTestSupport.fetch(
            #"{"user_info":{"metadata":{"preferred_username":false}}}"#, engine: engine)
        #expect(malformedMetadata.identity?.accountEmail == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `fetch surfaces rejected virtual key`(engine: ProviderPluginEngineKind) async throws {
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
            _ = try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
                .fetchUsage(
                    settings: ["LITELLM_BASE_URL": baseURL.absoluteString],
                    secrets: ["LITELLM_API_KEY": "sk-target"])
            Issue.record("expected authentication failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            let message = error.message
            #expect(message.contains("HTTP 401"))
            #expect(message.contains("Unauthorized"))
        } catch {
            Issue.record("expected authentication failure, got \(error)")
        }

        let requests = await transport.requests()
        #expect(requests.count == 1)
    }
}
