import Foundation
import Testing
@testable import CodexBarCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct GrokCreditsProxyFetcherTests {
    @Test
    func `constructs the CLI proxy request and parses weekly credits`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()
        GrokCreditsProxyStubURLProtocol.handler = { request in
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.timeoutInterval == 15)
            return try Self.response(
                for: request,
                body: """
                {
                  "config": {
                    "creditUsagePercent": 12.5,
                    "currentPeriod": {
                      "type": "USAGE_PERIOD_TYPE_WEEKLY",
                      "start": "2026-08-06T00:00:00Z",
                      "end": "2026-08-13T00:00:00Z"
                    },
                    "billingPeriodEnd": "2026-08-13T00:00:00Z",
                    "onDemandCap": { "val": 1000 },
                    "onDemandUsed": { "val": 250 }
                  }
                }
                """)
        }

        let snapshot = try await GrokCreditsProxyFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)
        let expectedReset = try Self.date("2026-08-13T00:00:00Z")

        #expect(GrokCreditsProxyStubURLProtocol.requests.count == 1)
        #expect(snapshot.usedPercent == 12.5)
        #expect(snapshot.resetsAt == expectedReset)
        #expect(snapshot.windowMinutes == 10080)
        #expect(snapshot.subscriptionTier == nil)
    }

    @Test
    func `measures only matching valid period bounds`() throws {
        let now = try Self.date("2026-08-12T00:00:00Z")
        let cases: [(String, Int?)] = [
            (#"""
            "billingPeriodStart":"2026-08-06T00:00:00Z","billingPeriodEnd":"2026-08-13T00:00:00Z"
            """#, 10080),
            (#"""
            "currentPeriod":{"start":"2026-07-13T00:00:00Z","end":"2026-08-13T00:00:00Z"}
            """#, 44640),
            (#"""
            "currentPeriod":{"end":"2026-08-13T00:00:00Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"end":"2026-08-13T00:00:00Z"},
            "billingPeriodStart":"2026-07-13T00:00:00Z","billingPeriodEnd":"2026-08-14T00:00:00Z"
            """#, nil),
            (#"""
            "currentPeriod":{"start":"invalid","end":"2026-08-13T00:00:00Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"start":"2026-08-14T00:00:00Z","end":"2026-08-21T00:00:00Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"start":"2026-08-11T00:00:00Z","end":"2026-08-10T00:00:00Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"start":"2026-08-11T00:00:00Z","end":"2026-08-11T00:00:00Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"start":"2026-08-11T00:00:00Z","end":"2026-08-11T00:00:30Z"}
            """#, nil),
            (#"""
            "currentPeriod":{"start":"2026-07-01T00:00:00Z","end":"invalid"},
            "billingPeriodStart":"2026-08-06T00:00:00Z","billingPeriodEnd":"2026-08-13T00:00:00Z"
            """#, 10080),
        ]
        for (period, expectedMinutes) in cases {
            let data = Data("{\"config\":{\"creditUsagePercent\":90,\(period)}}".utf8)
            let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(data, now: now)
            #expect(snapshot.usedPercent == 90)
            #expect(snapshot.windowMinutes == expectedMinutes)
        }
    }

    @Test
    func `plan overlay and unknown usage enrichment retain proxy period bounds`() async throws {
        let now = try Self.date("2026-08-12T00:00:00Z")
        let proxy = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"currentPeriod":{"start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"}}}
        """.utf8), now: now).applying(subscriptionTier: "SuperGrok Heavy")
        #expect(proxy.usedPercent == nil)
        #expect(proxy.windowMinutes == 10080)
        let enriched = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            proxy,
            credentials: Self.credentials,
            grpcBilling: { _ in
                GrokWebBillingSnapshot(usedPercent: 90, resetsAt: now.addingTimeInterval(3600))
            }).snapshot
        #expect(enriched.usedPercent == 90)
        #expect(enriched.resetsAt == proxy.resetsAt)
        #expect(enriched.windowMinutes == 10080)
        #expect(enriched.subscriptionTier == "SuperGrok Heavy")
    }

    @Test
    func `unknown proxy usage does not attach its products to grok dot com totals`() async throws {
        let now = try Self.date("2026-08-12T00:00:00Z")
        let proxy = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"currentPeriod":{"start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"},
        "productUsage":[{"product":"GrokBuild","usagePercent":3}]}}
        """.utf8), now: now)
        #expect(proxy.usedPercent == nil)
        #expect(proxy.windowMinutes == 10080)
        #expect(proxy.productUsage.isEmpty)

        let grpcSnapshots = [
            GrokWebBillingSnapshot(usedPercent: 12, resetsAt: nil),
            GrokWebBillingSnapshot(
                usedPercent: 0,
                resetsAt: nil,
                usedPercentIsWirePublished: false,
                usedPercentIsImplicitZero: true),
        ]
        for grpcSnapshot in grpcSnapshots {
            let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
                proxy,
                credentials: Self.credentials,
                grpcBilling: { _ in grpcSnapshot })
            let usage = GrokUsageSnapshot(
                billing: nil,
                webBilling: result.snapshot,
                credentials: nil,
                localSummary: nil,
                cliVersion: nil,
                updatedAt: now).toUsageSnapshot()

            #expect(result.snapshot.usedPercent == grpcSnapshot.usedPercent)
            #expect(result.snapshot.productUsage.isEmpty)
            #expect(usage.primary?.usedPercent == grpcSnapshot.usedPercent)
            #expect(!usage.details.contains { $0.title == "Usage breakdown" })
        }
    }

    @Test
    func `completion never pairs a duration with a different reset`() {
        let original = GrokWebBillingSnapshot(
            usedPercent: 90,
            resetsAt: Date(timeIntervalSince1970: 1_000_000),
            windowMinutes: 10080)
        let replaced = original.completing(with: GrokWebBillingSnapshot(
            usedPercent: nil,
            resetsAt: Date(timeIntervalSince1970: 2_000_000)))
        #expect(replaced.resetsAt == Date(timeIntervalSince1970: 2_000_000))
        #expect(replaced.windowMinutes == nil)
        let unchanged = original.completing(with: GrokWebBillingSnapshot(usedPercent: nil, resetsAt: nil))
        #expect(unchanged.resetsAt == original.resetsAt)
        #expect(unchanged.windowMinutes == 10080)
    }

    @Test
    func `derives percent from on demand cap and usage`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "onDemandCap": { "val": 1000.0 },
                    "onDemandUsed": { "val": 250.5 }
                  }
                }
                """.utf8))

        #expect(snapshot.usedPercent == 25.05)
        #expect(snapshot.resetsAt == nil)
    }

    @Test
    func `clamps an out of range credit usage percent`() throws {
        let over = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "creditUsagePercent": 104.2,
                    "billingPeriodEnd": "2026-08-13T00:00:00Z"
                  }
                }
                """.utf8))
        let under = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": { "creditUsagePercent": -3.5 }
                }
                """.utf8))

        #expect(over.usedPercent == 100)
        #expect(try over.resetsAt == (Self.date("2026-08-13T00:00:00Z")))
        #expect(under.usedPercent == 0)
    }

    @Test
    func `treats a period without usage as unknown`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "currentPeriod": { "end": "2026-08-13T00:00:00.123Z" },
                    "billingPeriodEnd": "2026-08-14T00:00:00Z"
                  }
                }
                """.utf8))
        let expectedReset = try Self.date("2026-08-13T00:00:00.123Z")

        #expect(snapshot.usedPercent == nil)
        #expect(snapshot.resetsAt == expectedReset)
        #expect(snapshot.subscriptionTier == nil)
    }

    @Test
    func `reads SuperGrok Heavy from the top-level subscription tier`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-16T18:42:45.537749+00:00",
              "end": "2026-08-23T18:42:45.537749+00:00"
            },
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "billingPeriodEnd": "2026-08-23T18:42:45.537749+00:00"
          },
          "subscriptionTier": "SuperGrok Heavy"
        }
        """.utf8))
        let expectedReset = try Self.date("2026-08-23T18:42:45.537749+00:00")

        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.usedPercent == nil)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `prefers config subscription tier over the envelope`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "creditUsagePercent": 8,
            "billingPeriodEnd": "2026-08-13T00:00:00Z",
            "subscriptionTier": "SuperGrok Heavy"
          },
          "subscriptionTier": "SuperGrok"
        }
        """.utf8))

        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.usedPercent == 8)
    }

    @Test
    func `rejects a tier-only response so legacy billing can run`() {
        #expect {
            _ = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
            {
              "config": { "onDemandCap": { "val": 0 } },
              "subscriptionTier": "supergrok_heavy"
            }
            """.utf8))
        } throws: { error in
            guard case GrokWebBillingError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `maps SuperGrok Heavy from credits subscription tier`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "subscriptionTier": "SUPERGROK_HEAVY",
                    "currentPeriod": { "end": "2026-08-13T00:00:00Z" }
                  }
                }
                """.utf8))
        let expectedReset = try Self.date("2026-08-13T00:00:00Z")

        #expect(snapshot.usedPercent == nil)
        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `keeps SuperGrok included percent when the credits payload reports it`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "subscriptionTier": "SUPERGROK",
                  "config": {
                    "creditUsagePercent": 57,
                    "billingPeriodEnd": "2026-08-13T00:00:00Z"
                  }
                }
                """.utf8))

        #expect(snapshot.usedPercent == 57)
        #expect(snapshot.subscriptionTier == "SuperGrok")
    }

    @Test
    func `rejects a response without usage or a period`() {
        #expect {
            _ = try GrokCreditsProxyFetcher.parseSnapshot(Data(#"{"config":{}}"#.utf8))
        } throws: { error in
            guard case GrokWebBillingError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `uses billing period end when current period end is missing`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY" },
                    "billingPeriodEnd": "2026-08-13T00:00:00Z"
                  }
                }
                """.utf8))
        let expectedReset = try Self.date("2026-08-13T00:00:00Z")

        #expect(snapshot.usedPercent == nil)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `unauthorized proxy response asks for grok login`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()
        GrokCreditsProxyStubURLProtocol.handler = { request in
            try Self.response(for: request, statusCode: 401, body: "unauthorized")
        }

        await #expect {
            _ = try await GrokCreditsProxyFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok login")
        }
    }

    @Test
    func `expired credentials fail before making a request`() async throws {
        let session = Self.makeSession()
        let endpoint = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        defer { GrokCreditsProxyStubURLProtocol.reset() }
        GrokCreditsProxyStubURLProtocol.reset()

        await #expect {
            _ = try await GrokCreditsProxyFetcher.fetch(
                credentials: Self.expiredCredentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            guard case GrokWebBillingError.missingCredentials = error else { return false }
            return true
        }
        #expect(GrokCreditsProxyStubURLProtocol.requests.isEmpty)
    }

    @Test
    func `recognizes WKE credential rejection and gives CLI-only guidance`() {
        let message = "No credentials presented. [WKE=unauthenticated:no-credentials]"

        #expect(GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 16, message: message))
        #expect(!GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 7, message: message))
        #expect(
            !GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: 16, message: "token expired"))

        let description = GrokWebBillingError.rpcFailed(16, message).localizedDescription
        #expect(description.contains("grok login"))
        #expect(!description.contains("Chrome"))
        #expect(GrokWebBillingError.isAuthenticationFailure(status: 16, message: message))
    }

    @Test
    func `proxy success short circuits legacy web billing`() async throws {
        let events = EventRecorder()
        let result = try await GrokWebFetchStrategy.fetchProxyFirst(
            credentials: Self.credentials,
            proxyBilling: { _ in
                events.append("proxy")
                return GrokWebBillingSnapshot(usedPercent: 12.5, resetsAt: nil)
            },
            legacyBilling: {
                events.append("legacy")
                return GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(usedPercent: 99, resetsAt: nil),
                    sourceLabel: "legacy",
                    authContext: .cookie("sso=legacy"))
            })

        #expect(events.values == ["proxy"])
        #expect(result.snapshot.usedPercent == 12.5)
        #expect(result.sourceLabel == "grok-cli-proxy")
        #expect(result.authContext.credentials?.accessToken == Self.credentials.accessToken)
    }

    @Test
    func `tier-only proxy parse failure falls through to legacy billing`() async throws {
        let events = EventRecorder()
        let result = try await GrokWebFetchStrategy.fetchProxyFirst(
            credentials: Self.credentials,
            proxyBilling: { _ in
                events.append("proxy")
                throw GrokWebBillingError.parseFailed
            },
            legacyBilling: {
                events.append("legacy")
                return GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(
                        usedPercent: 33,
                        resetsAt: Date(timeIntervalSince1970: 1_800_000_003)),
                    sourceLabel: "Chrome",
                    authContext: .cookie("sso=legacy"))
            })

        #expect(events.values == ["proxy", "legacy"])
        #expect(result.snapshot.usedPercent == 33)
        #expect(result.sourceLabel == "Chrome")
        #expect(result.authContext.cookieHeader == "sso=legacy")
    }

    @Test
    func `proxy failure falls through to legacy web billing`() async throws {
        let events = EventRecorder()
        let result = try await GrokWebFetchStrategy.fetchProxyFirst(
            credentials: Self.credentials,
            proxyBilling: { _ in
                events.append("proxy")
                throw URLError(.cannotConnectToHost)
            },
            legacyBilling: {
                events.append("legacy")
                return GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil),
                    sourceLabel: "Chrome",
                    authContext: .cookie("sso=legacy"))
            })

        #expect(events.values == ["proxy", "legacy"])
        #expect(result.snapshot.usedPercent == 42)
        #expect(result.sourceLabel == "Chrome")
        #expect(result.authContext.cookieHeader == "sso=legacy")
    }

    @Test
    func `proxy cancellation does not fall through to legacy web billing`() async throws {
        let events = EventRecorder()

        await #expect {
            _ = try await GrokWebFetchStrategy.fetchProxyFirst(
                credentials: Self.credentials,
                proxyBilling: { _ in
                    events.append("proxy")
                    throw CancellationError()
                },
                legacyBilling: {
                    events.append("legacy")
                    return GrokWebBillingResult(
                        snapshot: GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil),
                        sourceLabel: "Chrome",
                        authContext: .cookie("sso=legacy"))
                })
        } throws: { error in
            error is CancellationError
        }

        await #expect {
            _ = try await GrokWebFetchStrategy.fetchProxyFirst(
                credentials: Self.credentials,
                proxyBilling: { _ in
                    events.append("proxy")
                    throw URLError(.cancelled)
                },
                legacyBilling: {
                    events.append("legacy")
                    return GrokWebBillingResult(
                        snapshot: GrokWebBillingSnapshot(usedPercent: 42, resetsAt: nil),
                        sourceLabel: "Chrome",
                        authContext: .cookie("sso=legacy"))
                })
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }

        #expect(events.values == ["proxy", "proxy"])
    }

    @Test
    func `period-only credits ask grok dot com for the real percent`() async throws {
        let events = EventRecorder()
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: reset,
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            grpcBilling: { _ in
                events.append("grpc")
                return GrokWebBillingSnapshot(usedPercent: 20, resetsAt: nil)
            })

        #expect(events.values == ["grpc"])
        #expect(result.snapshot.usedPercent == 20)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(result.sourceLabel == "grok-web")
        #expect(result.authContext.credentials?.accessToken == Self.credentials.accessToken)
    }

    @Test
    func `recovered usage preserves the authoritative credits period reset`() async throws {
        let proxyReset = Date(timeIntervalSince1970: 1_800_000_003)
        let grpcReset = Date(timeIntervalSince1970: 1_800_604_803)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: proxyReset,
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            grpcBilling: { _ in
                GrokWebBillingSnapshot(usedPercent: 20, resetsAt: grpcReset)
            })

        #expect(result.snapshot.usedPercent == 20)
        #expect(result.snapshot.resetsAt == proxyReset)
        #expect(result.snapshot.subscriptionTier == "SuperGrok Heavy")
    }

    @Test
    func `a known credits percent is never second-guessed by grok dot com`() async throws {
        let events = EventRecorder()
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(usedPercent: 0, resetsAt: nil),
            credentials: Self.credentials,
            grpcBilling: { _ in
                events.append("grpc")
                return GrokWebBillingSnapshot(usedPercent: 77, resetsAt: nil)
            })

        #expect(events.values.isEmpty)
        #expect(result.snapshot.usedPercent == 0)
        #expect(result.sourceLabel == "grok-cli-proxy")
    }

    @Test
    func `usage stays unknown when grok dot com also publishes no percent`() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: reset,
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            grpcBilling: { _ in GrokWebBillingSnapshot(usedPercent: nil, resetsAt: nil) })

        #expect(result.snapshot.usedPercent == nil)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(result.sourceLabel == "grok-cli-proxy")
    }

    @Test
    func `a failing grok dot com retry keeps the period-only credits answer`() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(usedPercent: nil, resetsAt: reset),
            credentials: Self.credentials,
            grpcBilling: { _ in throw GrokWebBillingError.rpcFailed(16, "No credentials presented") })

        #expect(result.snapshot.usedPercent == nil)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.sourceLabel == "grok-cli-proxy")
    }

    @Test
    func `a cancelled grok dot com retry does not report unknown usage`() async throws {
        await #expect {
            _ = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
                GrokWebBillingSnapshot(usedPercent: nil, resetsAt: Date(timeIntervalSince1970: 1_800_000_003)),
                credentials: Self.credentials,
                grpcBilling: { _ in throw CancellationError() })
        } throws: { error in
            error is CancellationError
        }

        await #expect {
            _ = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
                GrokWebBillingSnapshot(usedPercent: nil, resetsAt: Date(timeIntervalSince1970: 1_800_000_003)),
                credentials: Self.credentials,
                grpcBilling: { _ in throw URLError(.cancelled) })
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }
    }

    @Test
    func `an unclassified grok dot com zero leaves usage unknown`() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: reset,
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            grpcBilling: { _ in
                GrokWebBillingSnapshot(
                    usedPercent: 0,
                    resetsAt: reset,
                    usedPercentIsWirePublished: false)
            })

        #expect(result.snapshot.usedPercent == nil)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(result.sourceLabel == "grok-cli-proxy")
    }

    @Test
    func `an inferred grok dot com percent above zero is still refused`() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: reset,
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            grpcBilling: { _ in
                // No parser produces this today. Only the no-usage-yet zero carries frame
                // evidence, so any other inferred reading stays unknown rather than published.
                GrokWebBillingSnapshot(
                    usedPercent: 20,
                    resetsAt: nil,
                    usedPercentIsWirePublished: false)
            })

        #expect(result.snapshot.usedPercent == nil)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.sourceLabel == "grok-cli-proxy")
    }

    @Test
    func `a published grok dot com zero still replaces unknown usage`() async throws {
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(usedPercent: nil, resetsAt: nil),
            credentials: Self.credentials,
            grpcBilling: { _ in GrokWebBillingSnapshot(usedPercent: 0, resetsAt: nil) })

        #expect(result.snapshot.usedPercent == 0)
        #expect(result.sourceLabel == "grok-web")
    }

    @Test
    func `a stalled grok dot com does not hold back the credits answer`() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_003)
        let started = ContinuousClock.now
        let result = try await GrokOAuthFetchStrategy.resolvingUnknownUsage(
            GrokWebBillingSnapshot(usedPercent: nil, resetsAt: reset),
            credentials: Self.credentials,
            budget: .milliseconds(50),
            grpcBilling: { _ in
                try await Task.sleep(for: .seconds(30))
                return GrokWebBillingSnapshot(usedPercent: 20, resetsAt: nil)
            })
        let elapsed = ContinuousClock.now - started

        #expect(result.snapshot.usedPercent == nil)
        #expect(result.snapshot.resetsAt == reset)
        #expect(result.sourceLabel == "grok-cli-proxy")
        #expect(elapsed < .seconds(5))
    }

    @Test
    func `unknown credits usage leaves the menu card without a rate window`() {
        let unknown = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: nil,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_003),
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000))
        let known = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: 20,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_003),
                subscriptionTier: "SuperGrok Heavy"),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000))

        #expect(unknown.toUsageSnapshot().primary == nil)
        #expect(known.toUsageSnapshot().primary?.usedPercent == 20)
    }

    private static let credentials = GrokCredentials(
        accessToken: "token-123",
        refreshToken: "refresh-123",
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: "user-123",
        email: "grok@example.com",
        firstName: "G",
        lastName: "Rok",
        teamId: "team-123",
        oidcIssuer: "https://auth.x.ai",
        oidcClientId: "client",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        createTime: Date(timeIntervalSince1970: 1_799_000_000))

    private static let expiredCredentials = GrokCredentials(
        accessToken: "expired-token",
        refreshToken: nil,
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: nil,
        email: nil,
        firstName: nil,
        lastName: nil,
        teamId: nil,
        oidcIssuer: nil,
        oidcClientId: nil,
        expiresAt: .distantPast,
        createTime: nil)

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokCreditsProxyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String) throws -> (HTTPURLResponse, Data)
    {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
        return (response, Data(body.utf8))
    }

    private static func date(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: raw))
    }
}

extension GrokCreditsProxyFetcherTests {
    @Test
    func `live weekly credits payload retains product composition`() throws {
        let now = try Self.date("2026-09-23T00:00:00Z")
        let payload = [
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","#,
            #""start":"2026-09-20T18:42:45.537749+00:00","#,
            #""end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":1.0,"onDemandCap":{"val":0},"#,
            #""onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":1.0}],"#,
            #""isUnifiedBillingUser":true,"#,
            #""prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","#,
            #""billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","#,
            #""billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}"#,
        ].joined()
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data(payload.utf8), now: now)

        #expect(snapshot.usedPercent == 1)
        #expect(try snapshot.resetsAt == (Self.date("2026-09-27T18:42:45.537749+00:00")))
        #expect(snapshot.windowMinutes == 10080)
        #expect(snapshot.productUsage == [GrokProductUsage(product: "GrokBuild", usedPercent: 1)])
    }

    @Test(arguments: LiveMultiProductCreditsPayload.all)
    func `live multi-product credits payloads compose the weekly total`(
        fixture: LiveMultiProductCreditsPayload) throws
    {
        let now = try Self.date("2026-09-25T01:00:00Z")
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data(fixture.payload.utf8), now: now)

        #expect(snapshot.usedPercent == fixture.usedPercent)
        #expect(snapshot.windowMinutes == 10080)
        #expect(try snapshot.resetsAt == Self.date("2026-09-27T18:42:45.537749+00:00"))
        #expect(snapshot.productUsage == fixture.products)
        #expect(snapshot.productUsage.reduce(0) { $0 + $1.usedPercent } == snapshot.usedPercent)
    }

    @Test
    func `live multi-product payload renders one bar and a sorted breakdown`() throws {
        let now = try Self.date("2026-09-25T01:00:00Z")
        let parsed = try GrokCreditsProxyFetcher.parseSnapshot(
            Data(LiveMultiProductCreditsPayload.p6.payload.utf8), now: now)
        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: parsed,
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
        let section = try #require(usage.details.first)

        #expect(usage.primary?.usedPercent == 6)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows?.isEmpty != false)
        #expect(usage.details.count == 1)
        #expect(section.title == "Usage breakdown")
        #expect(section.rows.map(\.label) == ["Grok Chat", "Grok Build"])
        #expect(section.rows.map(\.value) == ["4%", "2%"])
        #expect(section.rows.map(\.id) == ["grok.product.GrokChat", "grok.product.GrokBuild"])
        #expect(section.rows.allSatisfy { $0.progress == nil })
    }

    @Test
    func `proxy retains product wire order and unknown names`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":42,"productUsage":[
          {"product":"GrokImagine","usagePercent":2.5},
          {"product":" FutureGrok ","usagePercent":0},
          {"product":"GrokChat","usagePercent":39.5}
        ]}}
        """.utf8))

        #expect(snapshot.productUsage == [
            GrokProductUsage(product: "GrokImagine", usedPercent: 2.5),
            GrokProductUsage(product: "FutureGrok", usedPercent: 0),
            GrokProductUsage(product: "GrokChat", usedPercent: 39.5),
        ])
    }

    @Test
    func `malformed products do not change the weekly total or period`() throws {
        let now = try Self.date("2026-09-23T00:00:00Z")
        let base = #"""
        {"config":{"creditUsagePercent":42,"currentPeriod":{"start":"2026-09-20T00:00:00Z","end":"2026-09-27T00:00:00Z"}
        """#
        let baseline = try GrokCreditsProxyFetcher.parseSnapshot(Data("\(base)}}".utf8), now: now)
        let cases: [(String, [GrokProductUsage])] = [
            (#", "productUsage":null"#, []),
            (#", "productUsage":{}"#, []),
            (#", "productUsage":"wrong""#, []),
            (#", "productUsage":[{"product":"GrokBuild","usagePercent":"1"}]"#, []),
            (#", "productUsage":[{"usagePercent":1}]"#, []),
            (#", "productUsage":[{"product":42,"usagePercent":1}]"#, []),
            (#", "productUsage":[{"product":"GrokBuild"}]"#, []),
            (#", "productUsage":[{"product":"GrokBuild","usagePercent":-1}]"#, []),
            (#", "productUsage":[{"product":"  ","usagePercent":1}]"#, []),
            (#", "productUsage":[{"product":"GrokImagine","usagePercent":1e400}]"#, []),
            (#", "productUsage":[{"product":"GrokChat","usagePercent":42},42]"#, []),
        ]
        for (fragment, expectedProducts) in cases {
            let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("\(base)\(fragment)}}".utf8), now: now)
            #expect(snapshot.productUsage == expectedProducts)
            #expect(snapshot.usedPercent == baseline.usedPercent)
            #expect(snapshot.resetsAt == baseline.resetsAt)
            #expect(snapshot.windowMinutes == baseline.windowMinutes)
            #expect(snapshot.subscriptionTier == baseline.subscriptionTier)
            #expect(snapshot.usedPercentIsWirePublished == baseline.usedPercentIsWirePublished)
            #expect(snapshot.usedPercentIsImplicitZero == baseline.usedPercentIsImplicitZero)
        }
        #expect(baseline.productUsage.isEmpty)
    }

    @Test
    func `a malformed product entry drops the whole breakdown near the tolerance`() throws {
        let now = try Self.date("2026-09-23T00:00:00Z")
        let base = #"""
        {"config":{"creditUsagePercent":6,"currentPeriod":{"start":"2026-09-20T00:00:00Z",
        "end":"2026-09-27T00:00:00Z"},"subscriptionTier":"SUPERGROK_HEAVY"
        """#
        let baseline = try GrokCreditsProxyFetcher.parseSnapshot(Data("\(base)}}".utf8), now: now)
        let malformed = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        \(base),"productUsage":[{"product":"GrokChat","usagePercent":5},
        {"product":"GrokBuild","usagePercent":"1"}]}}
        """.utf8), now: now)

        #expect(malformed.productUsage.isEmpty)
        #expect(malformed.usedPercent == 6)
        #expect(malformed.resetsAt == baseline.resetsAt)
        #expect(malformed.windowMinutes == baseline.windowMinutes)
        #expect(malformed.subscriptionTier == baseline.subscriptionTier)
        #expect(malformed.usedPercentIsWirePublished == baseline.usedPercentIsWirePublished)
        #expect(malformed.usedPercentIsImplicitZero == baseline.usedPercentIsImplicitZero)

        let exactRemainder = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":5,"productUsage":[
        {"product":"GrokChat","usagePercent":5},{"usagePercent":1}]}}
        """.utf8), now: now)
        #expect(exactRemainder.usedPercent == 5)
        #expect(exactRemainder.productUsage.isEmpty)

        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: malformed,
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
        #expect(usage.details.isEmpty)
    }

    @Test
    func `products attach only to the published credit percentage`() throws {
        let cases: [(String, Double?)] = [
            (#""onDemandCap":{"val":100},"onDemandUsed":{"val":3}"#, 3),
            (#""billingPeriodEnd":"2026-09-27T00:00:00Z""#, nil),
        ]
        for (fields, percent) in cases {
            let payload = "{\"config\":{\(fields),\"productUsage\":[{\"product\":\"GrokBuild\",\"usagePercent\":3}]}}"
            let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data(payload.utf8))
            #expect(snapshot.usedPercent == percent)
            #expect(snapshot.productUsage.isEmpty)
        }
    }

    @Test
    func `product shares that do not compose the credit percentage are dropped`() throws {
        let now = try Self.date("2026-09-23T00:00:00Z")
        let base = #"""
        {"config":{"creditUsagePercent":30,"currentPeriod":{"start":"2026-09-20T00:00:00Z","end":"2026-09-27T00:00:00Z"}
        """#
        let baseline = try GrokCreditsProxyFetcher.parseSnapshot(Data("\(base)}}".utf8), now: now)
        let products = [
            #", "productUsage":[{"product":"GrokBuild","usagePercent":60}]"#,
            #", "productUsage":[{"product":"GrokBuild","usagePercent":20},{"product":"GrokChat","usagePercent":5}]"#,
        ]
        for fragment in products {
            let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("\(base)\(fragment)}}".utf8), now: now)
            #expect(snapshot.productUsage.isEmpty)
            #expect(snapshot.usedPercent == baseline.usedPercent)
            #expect(snapshot.resetsAt == baseline.resetsAt)
            #expect(snapshot.windowMinutes == baseline.windowMinutes)
            #expect(snapshot.subscriptionTier == baseline.subscriptionTier)
            #expect(snapshot.usedPercentIsWirePublished == baseline.usedPercentIsWirePublished)
            #expect(snapshot.usedPercentIsImplicitZero == baseline.usedPercentIsImplicitZero)
        }
    }

    @Test
    func `product shares within rounding of the credit percentage are kept`() throws {
        let rounded = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":10,"productUsage":[
          {"product":"GrokBuild","usagePercent":6.0},
          {"product":"GrokChat","usagePercent":3.6}
        ]}}
        """.utf8))
        #expect(rounded.usedPercent == 10)
        #expect(rounded.productUsage == [
            GrokProductUsage(product: "GrokBuild", usedPercent: 6),
            GrokProductUsage(product: "GrokChat", usedPercent: 3.6),
        ])

        let full = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":100,"productUsage":[
          {"product":"GrokBuild","usagePercent":46},
          {"product":"GrokAppBuilder","usagePercent":45},
          {"product":"GrokChat","usagePercent":7},
          {"product":"GrokAutomations","usagePercent":2}
        ]}}
        """.utf8))
        #expect(full.usedPercent == 100)
        #expect(full.productUsage == [
            GrokProductUsage(product: "GrokBuild", usedPercent: 46),
            GrokProductUsage(product: "GrokAppBuilder", usedPercent: 45),
            GrokProductUsage(product: "GrokChat", usedPercent: 7),
            GrokProductUsage(product: "GrokAutomations", usedPercent: 2),
        ])
    }

    @Test
    func `product shares use the raw overage credit percentage`() throws {
        let snapshot = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":120,"productUsage":[{"product":"GrokBuild","usagePercent":120}]}}
        """.utf8))
        #expect(snapshot.usedPercent == 100)
        #expect(snapshot.productUsage == [GrokProductUsage(product: "GrokBuild", usedPercent: 120)])
    }

    @Test
    func `billing snapshot copies keep product composition`() {
        let products = [GrokProductUsage(product: "GrokBuild", usedPercent: 1)]
        let proxyWithProducts = GrokWebBillingSnapshot(usedPercent: 1, resetsAt: nil, productUsage: products)
        let grpcLike = GrokWebBillingSnapshot(usedPercent: 2, resetsAt: nil)
        let otherProducts = GrokWebBillingSnapshot(
            usedPercent: 3,
            resetsAt: nil,
            productUsage: [GrokProductUsage(product: "GrokChat", usedPercent: 3)])
        #expect(proxyWithProducts.applying(subscriptionTier: "SuperGrok").productUsage == products)
        #expect(grpcLike.completing(with: proxyWithProducts).productUsage.isEmpty)
        #expect(proxyWithProducts.completing(with: grpcLike).productUsage == products)
        #expect(proxyWithProducts.completing(with: otherProducts).productUsage == products)
    }

    @Test
    func `product details share the primary weekly pool without extra bars`() throws {
        let products = [
            GrokProductUsage(product: "GrokBuild", usedPercent: 1),
            GrokProductUsage(product: "GrokChat", usedPercent: 5),
            GrokProductUsage(product: "GrokImagine", usedPercent: 0),
            GrokProductUsage(product: " FutureGrok ", usedPercent: 0.2),
            GrokProductUsage(product: "GrokAppBuilder", usedPercent: 5),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(usedPercent: 11.2, resetsAt: nil, productUsage: products),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
        let section = try #require(usage.details.first)

        #expect(usage.primary?.usedPercent == 11.2)
        #expect(usage.details.count == 1)
        #expect(section.title == "Usage breakdown")
        #expect(section.rows.map(\.id) == [
            "grok.product.GrokChat", "grok.product.GrokAppBuilder", "grok.product.GrokBuild",
            "grok.product.FutureGrok",
        ])
        #expect(section.rows.map(\.label) == ["Grok Chat", "Grok App Builder", "Grok Build", "FutureGrok"])
        #expect(section.rows.map(\.value) == ["5%", "5%", "1%", "<1%"])
        #expect(section.rows.allSatisfy { $0.progress == nil && $0.secondaryValue == nil })
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows?.isEmpty != false)
        #expect(GrokProductUsageDetails.sections(for: []).isEmpty)

        let empty = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(usedPercent: 11.2, resetsAt: nil),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
        let unknown = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(usedPercent: nil, resetsAt: nil, productUsage: products),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
        #expect(empty.details.isEmpty)
        #expect(unknown.primary == nil)
        #expect(unknown.details.isEmpty)
    }
}

struct LiveMultiProductCreditsPayload: Sendable {
    let payload: String
    let usedPercent: Double
    let products: [GrokProductUsage]

    static let p2 = Self(
        payload: [
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","#,
            #""start":"2026-09-20T18:42:45.537749+00:00","#,
            #""end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":2.0,"onDemandCap":{"val":0},"#,
            #""onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":1.0},"#,
            #"{"product":"GrokChat","usagePercent":1.0}],"isUnifiedBillingUser":true,"#,
            #""prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","#,
            #""billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","#,
            #""billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}"#,
        ].joined(),
        usedPercent: 2,
        products: [
            GrokProductUsage(product: "GrokBuild", usedPercent: 1),
            GrokProductUsage(product: "GrokChat", usedPercent: 1),
        ])

    static let p3 = Self(
        payload: [
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","#,
            #""start":"2026-09-20T18:42:45.537749+00:00","#,
            #""end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":3.0,"onDemandCap":{"val":0},"#,
            #""onDemandUsed":{"val":0},"productUsage":[{"product":"GrokChat","usagePercent":2.0},"#,
            #"{"product":"GrokBuild","usagePercent":1.0}],"isUnifiedBillingUser":true,"#,
            #""prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","#,
            #""billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","#,
            #""billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}"#,
        ].joined(),
        usedPercent: 3,
        products: [
            GrokProductUsage(product: "GrokChat", usedPercent: 2),
            GrokProductUsage(product: "GrokBuild", usedPercent: 1),
        ])

    static let p4 = Self(
        payload: [
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","#,
            #""start":"2026-09-20T18:42:45.537749+00:00","#,
            #""end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":4.0,"onDemandCap":{"val":0},"#,
            #""onDemandUsed":{"val":0},"productUsage":[{"product":"GrokChat","usagePercent":3.0},"#,
            #"{"product":"GrokBuild","usagePercent":1.0}],"isUnifiedBillingUser":true,"#,
            #""prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","#,
            #""billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","#,
            #""billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}"#,
        ].joined(),
        usedPercent: 4,
        products: [
            GrokProductUsage(product: "GrokChat", usedPercent: 3),
            GrokProductUsage(product: "GrokBuild", usedPercent: 1),
        ])

    static let p6 = Self(
        payload: [
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","#,
            #""start":"2026-09-20T18:42:45.537749+00:00","#,
            #""end":"2026-09-27T18:42:45.537749+00:00"},"creditUsagePercent":6.0,"onDemandCap":{"val":0},"#,
            #""onDemandUsed":{"val":0},"productUsage":[{"product":"GrokChat","usagePercent":4.0},"#,
            #"{"product":"GrokBuild","usagePercent":2.0}],"isUnifiedBillingUser":true,"#,
            #""prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","#,
            #""billingPeriodStart":"2026-09-20T18:42:45.537749+00:00","#,
            #""billingPeriodEnd":"2026-09-27T18:42:45.537749+00:00"}}"#,
        ].joined(),
        usedPercent: 6,
        products: [
            GrokProductUsage(product: "GrokChat", usedPercent: 4),
            GrokProductUsage(product: "GrokBuild", usedPercent: 2),
        ])

    static let all = [Self.p2, Self.p3, Self.p4, Self.p6]
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ value: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(value)
    }
}

private final class GrokCreditsProxyStubURLProtocol: URLProtocol {
    private static let state = State()

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.state.handler }
        set { Self.state.handler = newValue }
    }

    static var requests: [URLRequest] {
        state.requests
    }

    static func reset() {
        self.state.reset()
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.record(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        private var storedRequests: [URLRequest] = []

        var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
            get {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.storedHandler
            }
            set {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.storedHandler = newValue
            }
        }

        var requests: [URLRequest] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storedRequests
        }

        func record(_ request: URLRequest) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedRequests.append(request)
        }

        func reset() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storedHandler = nil
            self.storedRequests = []
        }
    }
}
