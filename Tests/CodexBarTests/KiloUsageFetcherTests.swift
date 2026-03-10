import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct KiloUsageFetcherTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        env: [String: String] = [:],
        sourceMode: ProviderSourceMode = .api) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: browserDetection)
    }

    @Test
    func batchURLUsesAuthenticatedTRPCBatchFormat() throws {
        let baseURL = try #require(URL(string: "https://kilo.example/trpc"))
        let url = try KiloUsageFetcher._buildBatchURLForTesting(baseURL: baseURL)

        #expect(url.path.contains("user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod"))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let batch = components.queryItems?.first(where: { $0.name == "batch" })?.value
        let inputValue = components.queryItems?.first(where: { $0.name == "input" })?.value

        #expect(batch == "1")
        let requiredInput = try #require(inputValue)
        let inputData = Data(requiredInput.utf8)
        let inputObject = try #require(try JSONSerialization.jsonObject(with: inputData) as? [String: Any])
        let first = try #require(inputObject["0"] as? [String: Any])
        let second = try #require(inputObject["1"] as? [String: Any])
        let third = try #require(inputObject["2"] as? [String: Any])

        #expect(inputObject.keys.contains("0"))
        #expect(inputObject.keys.contains("1"))
        #expect(inputObject.keys.contains("2"))
        #expect(first["json"] is NSNull)
        #expect(second["json"] is NSNull)
        #expect(third["json"] is NSNull)
    }

    @Test
    func parseSnapshotMapsBusinessFieldsAndIdentity() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "blocks": [
                    {
                      "usedCredits": 25,
                      "totalCredits": 100,
                      "remainingCredits": 75
                    }
                  ]
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "plan": {
                    "name": "Kilo Pass Pro"
                  }
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "enabled": true,
                  "paymentMethod": "visa"
                }
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.identity?.providerID == .kilo)
        #expect(snapshot.loginMethod(for: .kilo)?.contains("Kilo Pass Pro") == true)
        #expect(snapshot.loginMethod(for: .kilo)?.contains("Auto top-up") == true)
    }

    @Test
    func parseSnapshotMapsKiloPassWindowFromSubscriptionState() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "creditBlocks": [
                  {
                    "id": "cb-1",
                    "effective_date": "2026-02-01T00:00:00Z",
                    "expiry_date": null,
                    "balance_mUsd": 19000000,
                    "amount_mUsd": 19000000,
                    "is_free": false
                  }
                ],
                "totalBalance_mUsd": 19000000,
                "autoTopUpEnabled": false
              }
            }
          },
          {
            "result": {
              "data": {
                "subscription": {
                  "tier": "tier_19",
                  "currentPeriodUsageUsd": 0,
                  "currentPeriodBaseCreditsUsd": 19.0,
                  "currentPeriodBonusCreditsUsd": 9.5,
                  "nextBillingAt": "2026-03-28T04:00:00.000Z"
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "enabled": false,
                "amountCents": 5000,
                "paymentMethod": null
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.secondary?.resetsAt != nil)
        #expect(snapshot.secondary?.resetDescription == "$0.00 / $19.00 (+ $9.50 bonus)")
        #expect(snapshot.loginMethod(for: .kilo) == "Starter · Auto top-up: off")
    }

    @Test
    func parseSnapshotMapsKnownTierNamesAndDefaultsToKiloPass() throws {
        let proTierJSON = """
        [
          { "result": { "data": { "creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false } } },
          { "result": { "data": { "subscription": { "tier": "tier_49" } } } },
          { "result": { "data": { "enabled": false, "paymentMethod": null } } }
        ]
        """
        let proTierSnapshot = try KiloUsageFetcher._parseSnapshotForTesting(Data(proTierJSON.utf8)).toUsageSnapshot()
        #expect(proTierSnapshot.loginMethod(for: .kilo) == "Pro · Auto top-up: off")

        let noTierJSON = """
        [
          { "result": { "data": { "creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false } } },
          { "result": { "data": { "subscription": {
            "currentPeriodUsageUsd": 1.0,
            "currentPeriodBaseCreditsUsd": 19.0
          } } } },
          { "result": { "data": { "enabled": false, "paymentMethod": null } } }
        ]
        """
        let noTierSnapshot = try KiloUsageFetcher._parseSnapshotForTesting(Data(noTierJSON.utf8)).toUsageSnapshot()
        #expect(noTierSnapshot.loginMethod(for: .kilo) == "Kilo Pass · Auto top-up: off")
    }

    @Test
    func parseSnapshotUsesAutoTopUpAmountWhenEnabledWithoutPaymentMethod() throws {
        let json = """
        [
          { "result": { "data": { "creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": true } } },
          { "result": { "data": { "subscription": null } } },
          { "result": { "data": { "enabled": true, "amountCents": 5000, "paymentMethod": null } } }
        ]
        """

        let snapshot = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8)).toUsageSnapshot()
        #expect(snapshot.loginMethod(for: .kilo) == "Auto top-up: $50")
    }

    @Test
    func parseSnapshotFallbackPassFieldsUseMicroDollarScale() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "blocks": [
                    {
                      "usedCredits": 0,
                      "totalCredits": 19,
                      "remainingCredits": 19
                    }
                  ]
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "planName": "Starter",
                  "amount_mUsd": 28500000,
                  "used_mUsd": 3500000,
                  "bonus_mUsd": 9500000,
                  "nextRenewalAt": "2026-03-28T04:00:00.000Z"
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "enabled": false,
                  "paymentMethod": null
                }
              }
            }
          }
        ]
        """

        let snapshot = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8)).toUsageSnapshot()
        #expect(snapshot.secondary?.resetDescription == "$3.50 / $19.00 (+ $9.50 bonus)")
        #expect(snapshot.loginMethod(for: .kilo) == "Starter · Auto top-up: off")
    }

    @Test
    func parseSnapshotTreatsEmptyAndNullBusinessFieldsAsNoDataSuccess() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "blocks": []
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "plan": {
                    "name": null
                  }
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "enabled": null,
                  "paymentMethod": null
                }
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.providerID == .kilo)
        #expect(snapshot.loginMethod(for: .kilo) == nil)
    }

    @Test
    func parseSnapshotKeepsSparseIndexedObjectRoutingByProcedureIndex() throws {
        let json = """
        {
          "0": {
            "result": {
              "data": {
                "json": {
                  "creditsUsed": 10,
                  "creditsRemaining": 90
                }
              }
            }
          },
          "2": {
            "result": {
              "data": {
                "json": {
                  "planName": "wrong-route",
                  "enabled": true,
                  "method": "visa"
                }
              }
            }
          }
        }
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.loginMethod(for: .kilo) == "Auto top-up: visa")
    }

    @Test
    func parseSnapshotUsesTopLevelCreditsUsedFallback() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "creditsUsed": 40,
                  "creditsRemaining": 60
                }
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 40)
        #expect(snapshot.primary?.resetDescription == "40/100 credits")
    }

    @Test
    func parseSnapshotKeepsZeroTotalVisibleWhenActivityExists() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "creditsUsed": 0,
                  "creditsRemaining": 0
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "planName": "Kilo Pass Pro"
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "enabled": true,
                  "paymentMethod": "visa"
                }
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.remainingPercent == 0)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription == "0/0 credits")
        #expect(snapshot.loginMethod(for: .kilo)?.contains("Auto top-up: visa") == true)
    }

    @Test
    func parseSnapshotTreatsZeroBalanceWithoutCreditBlocksAsVisibleZeroTotal() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "creditBlocks": [],
                "totalBalance_mUsd": 0,
                "isFirstPurchase": true,
                "autoTopUpEnabled": false
              }
            }
          },
          {
            "result": {
              "data": {
                "subscription": null
              }
            }
          },
          {
            "result": {
              "data": {
                "enabled": false,
                "amountCents": 5000,
                "paymentMethod": null
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.remainingPercent == 0)
        #expect(snapshot.primary?.resetDescription == "0/0 credits")
        #expect(snapshot.loginMethod(for: .kilo) == "Auto top-up: off")
    }

    @Test
    func parseSnapshotDegradesOptionalAutoTopUpTRPCError() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "creditsUsed": 10,
                  "creditsRemaining": 90
                }
              }
            }
          },
          {
            "result": {
              "data": {
                "json": {
                  "planName": "Starter"
                }
              }
            }
          },
          {
            "error": {
              "json": {
                "message": "Internal server error",
                "data": {
                  "code": "INTERNAL_SERVER_ERROR"
                }
              }
            }
          }
        ]
        """

        let parsed = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.loginMethod(for: .kilo) == "Starter")
    }

    @Test
    func parseSnapshotKeepsRequiredProcedureTRPCErrorFatal() {
        let json = """
        [
          {
            "result": {
              "data": {
                "json": {
                  "creditsUsed": 10,
                  "creditsRemaining": 90
                }
              }
            }
          },
          {
            "error": {
              "json": {
                "message": "Unauthorized",
                "data": {
                  "code": "UNAUTHORIZED"
                }
              }
            }
          }
        ]
        """

        #expect {
            _ = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard let kiloError = error as? KiloUsageError else { return false }
            guard case .unauthorized = kiloError else { return false }
            return true
        }
    }

    @Test
    func parseSnapshotMapsUnauthorizedTRPCError() {
        let json = """
        [
          {
            "error": {
              "json": {
                "message": "Unauthorized",
                "data": {
                  "code": "UNAUTHORIZED"
                }
              }
            }
          }
        ]
        """

        #expect {
            _ = try KiloUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard let kiloError = error as? KiloUsageError else { return false }
            guard case .unauthorized = kiloError else { return false }
            return true
        }
    }

    @Test
    func parseSnapshotMapsInvalidJSONToParseError() {
        #expect {
            _ = try KiloUsageFetcher._parseSnapshotForTesting(Data("not-json".utf8))
        } throws: { error in
            guard let kiloError = error as? KiloUsageError else { return false }
            guard case .parseFailed = kiloError else { return false }
            return true
        }
    }

    @Test
    func statusErrorMappingCoversAuthAndServerFailures() {
        #expect(KiloUsageFetcher._statusErrorForTesting(401) == .unauthorized)
        #expect(KiloUsageFetcher._statusErrorForTesting(403) == .unauthorized)
        #expect(KiloUsageFetcher._statusErrorForTesting(404) == .endpointNotFound)

        guard let serviceError = KiloUsageFetcher._statusErrorForTesting(503) else {
            Issue.record("Expected service unavailable mapping")
            return
        }
        guard case let .serviceUnavailable(statusCode) = serviceError else {
            Issue.record("Expected service unavailable mapping")
            return
        }
        #expect(statusCode == 503)
    }

    @Test
    func fetchUsageWithoutCredentialsFailsFast() async {
        await #expect(throws: KiloUsageError.missingCredentials) {
            _ = try await KiloUsageFetcher.fetchUsage(apiKey: "  ", environment: [:])
        }
    }

    @Test
    func descriptorFetchOutcomeWithoutCredentialsReturnsActionableError() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let outcome = await descriptor.fetchOutcome(context: self.makeContext())

        switch outcome.result {
        case .success:
            Issue.record("Expected missing credentials failure")
        case let .failure(error):
            #expect((error as? KiloUsageError) == .missingCredentials)
        }

        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts.first?.strategyID == "kilo.api")
        #expect(outcome.attempts.first?.wasAvailable == true)
    }

    @Test
    func descriptorAPIModeIgnoresCLISessionFallback() async throws {
        let homeDirectory = try self.makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        try self.writeKiloAuthFile(
            homeDirectory: homeDirectory,
            contents: #"{"kilo":{"access":"file-token"}}"#)

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let outcome = await descriptor.fetchOutcome(context: self.makeContext(
            env: ["HOME": homeDirectory.path],
            sourceMode: .api))

        switch outcome.result {
        case .success:
            Issue.record("Expected missing API credentials failure")
        case let .failure(error):
            #expect((error as? KiloUsageError) == .missingCredentials)
        }

        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts.first?.strategyID == "kilo.api")
    }

    @Test
    func descriptorCLIModeMissingSessionReturnsActionableError() async throws {
        let homeDirectory = try self.makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let expectedPath = KiloSettingsReader.defaultAuthFileURL(homeDirectory: homeDirectory).path

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let outcome = await descriptor.fetchOutcome(context: self.makeContext(
            env: ["HOME": homeDirectory.path],
            sourceMode: .cli))

        switch outcome.result {
        case .success:
            Issue.record("Expected missing CLI session failure")
        case let .failure(error):
            #expect((error as? KiloUsageError) == .cliSessionMissing(expectedPath))
        }

        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts.first?.strategyID == "kilo.cli")
    }

    @Test
    func descriptorAutoModeFallsBackFromAPIToCLI() async throws {
        let homeDirectory = try self.makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }
        let expectedPath = KiloSettingsReader.defaultAuthFileURL(homeDirectory: homeDirectory).path

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let outcome = await descriptor.fetchOutcome(context: self.makeContext(
            env: ["HOME": homeDirectory.path],
            sourceMode: .auto))

        switch outcome.result {
        case .success:
            Issue.record("Expected missing CLI session failure after API fallback")
        case let .failure(error):
            #expect((error as? KiloUsageError) == .cliSessionMissing(expectedPath))
        }

        #expect(outcome.attempts.count == 2)
        #expect(outcome.attempts.map(\.strategyID) == ["kilo.api", "kilo.cli"])
    }

    @Test
    func apiStrategyFallsBackOnUnauthorizedOnlyInAutoMode() {
        let strategy = KiloAPIFetchStrategy()
        #expect(strategy.shouldFallback(
            on: KiloUsageError.unauthorized,
            context: self.makeContext(sourceMode: .auto)))
        #expect(!strategy.shouldFallback(
            on: KiloUsageError.unauthorized,
            context: self.makeContext(sourceMode: .api)))
    }

    @Test
    func apiStrategyFallsBackOnMissingCredentialsOnlyInAutoMode() {
        let strategy = KiloAPIFetchStrategy()
        #expect(strategy.shouldFallback(
            on: KiloUsageError.missingCredentials,
            context: self.makeContext(sourceMode: .auto)))
        #expect(!strategy.shouldFallback(
            on: KiloUsageError.missingCredentials,
            context: self.makeContext(sourceMode: .api)))
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeKiloAuthFile(homeDirectory: URL, contents: String) throws {
        let fileURL = KiloSettingsReader.defaultAuthFileURL(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
