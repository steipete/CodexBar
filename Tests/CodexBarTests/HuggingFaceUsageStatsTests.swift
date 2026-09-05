import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

private struct HuggingFaceBillingHTTPCase: Sendable {
    let status: Int
    let expectedKind: ProviderFetchClassifiedError.Kind
    let headers: [String: String]
    let messageFragment: String?
    let retryAfterSeconds: Double?
}

struct HuggingFaceUsageStatsTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `current billing period spend and identity match the finite API payload`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        let snapshot = try await Self.fetch(engine: engine, transport: transport)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.providerCost?.used == 2.41)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.nextRegenAmount == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.providerID == .huggingface)
        #expect(snapshot.identity?.accountEmail == "fixture@example.com")
        #expect(snapshot.identity?.accountID == "fixture-user")
        #expect(snapshot.identity?.loginMethod == "PRO")
        #expect(snapshot.detailRow(label: "Billing period")?.value == "2026-08-01 – 2026-09-01")
        #expect(snapshot.detailRow(label: "Reported spend")?.value == "$2.41")
        #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
        #expect(snapshot.details.map(\.title) == ["Billing summary", "Usage breakdown"])
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$1.75", "$0.66"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing parser reports only the selected usage endpoint categories`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        let snapshot = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()

        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.detailRow(label: "Reported spend")?.value == "$2.41")
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(requests.map { $0.url?.path } == [
            "/api/settings/billing/usage",
            "/api/whoami-v2",
        ])
        #expect(requests.allSatisfy { $0.url?.path != "/api/settings/billing/usage-v2" })
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.costUsage == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `current billing period aggregates categories exactly once`(engine: ProviderPluginEngineKind) async throws {
        let usage = Self.usageBody(
            endpoints: #"[{"totalCostMicroUSD":7654321}]"#,
            spaces: #"[{"totalCostMicroUSD":1234567}]"#)
        let snapshot = try await Self.fetch(
            engine: engine,
            billingBody: Self.billingBody(usage: usage))

        #expect(snapshot.providerCost?.used == 8.888888)
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$7.65", "$1.23"])
        #expect(snapshot.details.map(\.title) == ["Billing summary", "Usage breakdown"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero usage remains a valid exact spend snapshot`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine,
            billingBody: Self.billingBody(usage: Self.usageBody(endpoints: "[]", spaces: "[]")))

        #expect(snapshot.providerCost?.used == 0)
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$0.00", "$0.00"])
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free grant does not create a quota or balance snapshot`(engine: ProviderPluginEngineKind) async throws {
        let usage = Self.usageBody(
            endpoints: #"[{"totalCostMicroUSD":500000,"freeGrant":true}]"#,
            spaces: "[]")
        let snapshot = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))

        #expect(snapshot.providerCost?.used == 0.5)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.nextRegenAmount == nil)
        #expect(snapshot.providerCost?.limit == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `only a positively known PRO plan is rendered`(engine: ProviderPluginEngineKind) async throws {
        let profiles = [
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":true}"#,
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":false}"#,
            #"{"name":"fixture-user","email":"fixture@example.com"}"#,
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":null}"#,
        ]

        for (index, profile) in profiles.enumerated() {
            let snapshot = try await Self.fetch(engine: engine, profileBody: profile)
            if index == 0 {
                #expect(snapshot.identity?.loginMethod == "PRO")
                #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
            } else {
                #expect(snapshot.identity?.loginMethod == nil)
                #expect(snapshot.detailRow(label: "Plan") == nil)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed plan type leaves billing usable without identity`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine,
            profileBody: #"{"name":"fixture-user","isPro":"PRO"}"#)
        #expect(snapshot.providerCost?.used == 2.41)
        #expect(snapshot.identity == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed cost values are classified as parse failures`(engine: ProviderPluginEngineKind) async throws {
        let usages = [
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":"1"}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":-1}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":1e309}]"#, spaces: "[]"),
            Self.usageBody(
                endpoints: #"[{"totalCostMicroUSD":9007199254740991},{"totalCostMicroUSD":1}]"#,
                spaces: "[]"),
        ]

        for usage in usages {
            do {
                _ = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))
                Issue.record("Expected malformed Hugging Face cost to fail: \(usage)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed usage categories and billing dates are classified as parse failures`(
        engine: ProviderPluginEngineKind) async throws
    {
        let malformedUsages = [
            #"{"Endpoints":{},"Spaces":[]}"#,
            #"{"Endpoints":[null],"Spaces":[]}"#,
            #"{"Endpoints":[[]],"Spaces":[]}"#,
            #"{"Endpoints":[],"Spaces":null}"#,
        ]
        for usage in malformedUsages {
            do {
                _ = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))
                Issue.record("Expected malformed Hugging Face usage data to fail: \(usage)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face usage error: \(error)")
            }
        }

        let malformedPeriods = [
            ("not-a-date", "2026-09-01T00:00:00Z"),
            ("2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z"),
        ]
        for (start, end) in malformedPeriods {
            do {
                _ = try await Self.fetch(
                    engine: engine,
                    billingBody: Self.billingBody(periodStart: start, periodEnd: end))
                Issue.record("Expected malformed Hugging Face billing period to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face period error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing HTTP errors preserve classifications and diagnostics`(engine: ProviderPluginEngineKind) async throws {
        let cases: [HuggingFaceBillingHTTPCase] = [
            .init(
                status: 401,
                expectedKind: .authenticationExpired,
                headers: [:],
                messageFragment: "invalid or expired",
                retryAfterSeconds: nil),
            .init(
                status: 403,
                expectedKind: .permissionDenied,
                headers: [:],
                messageFragment: "Billing read",
                retryAfterSeconds: nil),
            .init(status: 404, expectedKind: .apiFailure, headers: [:], messageFragment: nil, retryAfterSeconds: nil),
            .init(status: 418, expectedKind: .apiFailure, headers: [:], messageFragment: nil, retryAfterSeconds: nil),
            .init(
                status: 429,
                expectedKind: .rateLimited,
                headers: ["RateLimit": "\"api\";r=0;t=33"],
                messageFragment: "33",
                retryAfterSeconds: 10),
            .init(
                status: 429,
                expectedKind: .rateLimited,
                headers: ["Retry-After": "7.5"],
                messageFragment: "7.5",
                retryAfterSeconds: 7.5),
            .init(
                status: 429,
                expectedKind: .rateLimited,
                headers: ["RateLimit": "\"api\";r=0;t=not-a-number", "Retry-After": "also-invalid"],
                messageFragment: nil,
                retryAfterSeconds: nil),
            .init(
                status: 503,
                expectedKind: .providerUnavailable,
                headers: [:],
                messageFragment: nil,
                retryAfterSeconds: nil),
        ]

        for testCase in cases {
            let status = testCase.status
            do {
                _ = try await Self.fetch(
                    engine: engine,
                    billingBody: #"{"error":"hf_fixture_token"}"#,
                    billingStatus: status,
                    billingHeaders: testCase.headers)
                Issue.record("Expected Hugging Face HTTP \(status) to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == testCase.expectedKind)
                #expect(!error.message.contains("hf_fixture_token"))
                if let messageFragment = testCase.messageFragment {
                    #expect(error.message.contains(messageFragment))
                }
                if let retryAfterSeconds = testCase.retryAfterSeconds {
                    #expect(error.retryAfterSeconds == retryAfterSeconds)
                } else if status == 429 {
                    #expect(error.retryAfterSeconds == nil)
                }
            } catch {
                Issue.record("Unexpected Hugging Face HTTP error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `requests stay on the official origin and carry only the bearer token`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        _ = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()

        #expect(requests.count == 2)
        #expect(requests.map { $0.url?.path } == [
            "/api/settings/billing/usage",
            "/api/whoami-v2",
        ])
        for request in requests {
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture_token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(!url.absoluteString.contains("hf_fixture_token"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing endpoint does not depend on the account name`(engine: ProviderPluginEngineKind) async throws {
        let transport = Self.transport(profileBody: #"{"name":"fixture/user?x","email":"fixture@example.com"}"#)
        _ = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()
        let billingRequest = try #require(requests.first { $0.url?.path == "/api/settings/billing/usage" })
        #expect(billingRequest.url?.path == "/api/settings/billing/usage")
        #expect(billingRequest.url?.absoluteString.contains("fixture") == false)
    }

    @Test
    func `descriptor and credentials expose only the scoped API surface`() async throws {
        #expect(HuggingFaceSettingsReader.token(environment: [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "  'hf_fixture_token'  ",
        ]) == "hf_fixture_token")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("HuggingFaceUsageStatsTests-no-token-\(UUID().uuidString)")
        #expect(HuggingFaceSettingsReader.token(
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "  \"  \" "],
            homeDirectory: isolatedHome) == nil)

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)
        #expect(descriptor.metadata.displayName == "Hugging Face")
        #expect(descriptor.metadata.shortDisplayName == "HF")
        #expect(descriptor.metadata.sessionLabel == "Spend")
        #expect(descriptor.metadata.weeklyLabel == "Spend")
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.metadata.isPrimaryProvider == false)
        #expect(descriptor.metadata.supportsCredits == false)
        #expect(descriptor.metadata.creditsHint == "Spend reported by Hugging Face billing")
        #expect(descriptor.tokenCost.supportsTokenCost == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .web])
        #expect(descriptor.cli.name == "huggingface")
        #expect(descriptor.cli.aliases == ["hf"])
        #expect(descriptor.metadata.dashboardURL == "https://huggingface.co/settings/billing")
        #expect(descriptor.metadata.statusPageURL == nil)
        #expect(descriptor.metadata.statusLinkURL == nil)

        let config = ProviderConfig(id: .huggingface, apiKey: "configured-token")
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [HuggingFaceSettingsReader.tokenEnvironmentKey: "environment-token"],
            provider: .huggingface,
            config: config)
        #expect(environment[HuggingFaceSettingsReader.tokenEnvironmentKey] == "configured-token")
        #expect(ProviderTokenResolver.token(for: .huggingface, environment: environment) == "configured-token")
        #expect(TokenAccountSupportCatalog.envOverride(for: .huggingface, token: "account-token") == [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "account-token",
        ])

        let context = Self.fetchContext(environment: [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token",
        ])
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let strategy = try #require(strategies.first)
        #expect(strategies.map(\.id) == ["huggingface.js"])
        #expect(strategy.kind == .apiToken)
        #expect(await strategy.isAvailable(context))

        let webContext = Self.fetchContext(
            sourceMode: .web,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings())
        let webStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(webContext)
        #expect(webStrategies.map(\.id) == ["huggingface.web"])
        #expect(webStrategies.first?.kind == .web)

        let autoContext = Self.fetchContext(
            sourceMode: .auto,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings())
        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(autoContext)
        #expect(autoStrategies.map(\.id) == ["huggingface.js"])
        #expect(autoStrategies.first?.kind == .apiToken)
    }

    @Test
    func `current server rendered wallet uses USD without asserting account ownership`() throws {
        let current = Self.dataProps(
            #"{"entity":{"type":"user","name":"unverified-name","user":"fixture-user","currentBalanceUsd":12.345}}"#)
        let snapshot = try HuggingFaceWebCreditsParser.parseSnapshot(current)
        #expect(snapshot.balanceUSD == 12.345)

        let zero = Self.dataProps(
            #"{"entity":{"type":"user","name":"unverified-name","user":"fixture-user","currentBalanceUsd":0}}"#)
        #expect(try HuggingFaceWebCreditsParser.parse(zero) == 0)
        #expect(Self.parserError("<div>Credits remaining: $12.34</div>") == .unavailable)
    }

    @Test
    func `legacy invoice credits convert once`() throws {
        let legacy = Self.dataProps(#"{"invoiceCreditsCents":7250}"#)
        let snapshot = try HuggingFaceWebCreditsParser.parseSnapshot(legacy)
        #expect(snapshot.balanceUSD == 72.5)

        let both = Self.dataProps(
            #"{"invoiceCreditsCents":7250,"entity":{"type":"user","currentBalanceUsd":8.125}}"#)
        #expect(try HuggingFaceWebCreditsParser.parse(both) == 8.125)
    }

    @Test
    func `wallet parser rejects invalid or ambiguous upstream values`() {
        let currentCases: [(String, HuggingFaceWebCreditsParser.ParseError)] = [
            (#"{"entity":{"type":"user","currentBalanceUsd":null}}"#, .invalidCurrentBalance),
            (#"{"entity":{"type":"user","currentBalanceUsd":"12.34"}}"#, .invalidCurrentBalance),
            (#"{"entity":{"type":"user","currentBalanceUsd":true}}"#, .invalidCurrentBalance),
            (#"{"entity":{"type":"user","currentBalanceUsd":-0.01}}"#, .invalidCurrentBalance),
            (#"{"entity":{"type":"organization","currentBalanceUsd":12.34}}"#, .invalidCurrentBalance),
        ]
        for (json, expected) in currentCases {
            #expect(Self.parserError(Self.dataProps(json)) == expected)
        }

        let legacyCases: [(String, HuggingFaceWebCreditsParser.ParseError)] = [
            (#"{"invoiceCreditsCents":12.5}"#, .invalidLegacyBalance),
            (#"{"invoiceCreditsCents":-1}"#, .invalidLegacyBalance),
            (#"{"invoiceCreditsCents":9007199254740992}"#, .invalidLegacyBalance),
            (#"{"invoiceCreditsCents":true}"#, .invalidLegacyBalance),
        ]
        for (json, expected) in legacyCases {
            #expect(Self.parserError(Self.dataProps(json)) == expected)
        }

        let ambiguousCurrent = Self.dataProps(#"{"entity":{"type":"user","currentBalanceUsd":1}}"#)
            + Self.dataProps(#"{"entity":{"type":"user","currentBalanceUsd":2}}"#)
        #expect(Self.parserError(ambiguousCurrent) == .ambiguousCurrentBalance)

        let ambiguousLegacy = Self.dataProps(#"{"invoiceCreditsCents":100}"#)
            + Self.dataProps(#"{"invoiceCreditsCents":200}"#)
        #expect(Self.parserError(ambiguousLegacy) == .ambiguousLegacyBalance)
    }

    @Test
    func `wallet parser decodes only billing div data props attributes`() throws {
        let unrelated = Self.dataProps(#"{"kind":"navigation"}"#)
        let billing = Self.dataProps(
            #"{"entity":{"type":"user","name":"fixture-user","currentBalanceUsd":4.5}}"#)
        #expect(try HuggingFaceWebCreditsParser.parse(unrelated + billing) == 4.5)

        let nonDiv = #"<span data-props="{&quot;invoiceCreditsCents&quot;:100}">ignored</span>"#
        #expect(Self.parserError(nonDiv) == .unavailable)
        #expect(Self.parserError(#"<div data-props="{&quot;entity&quot;:"></div>"#) == .malformedJSON)
    }

    @Test
    func `web wallet request carries only the session cookie and returns no account identity`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let payload =
                #"{"entity":{"type":"user","name":"unverified-name","user":"fixture-user","currentBalanceUsd":12.34}}"#
            return try Self.htmlResponse(
                url: url,
                body: Self.dataProps(payload),
                statusCode: 200)
        }
        let context = Self.fetchContext(sourceMode: .web, settings: Self.manualCookieSettings())
        let strategy = HuggingFaceWebFetchStrategy(
            transport: transport,
            resolveCookieHeader: { _ in "session=fixture" })

        #expect(await strategy.isAvailable(context))
        let result = try await strategy.fetch(context)
        let request = try #require(await transport.requests().first)

        #expect(result.strategyID == "huggingface.web")
        #expect(result.strategyKind == .web)
        #expect(result.sourceLabel == "web")
        #expect(result.usage.providerCost?.used == 0)
        #expect(result.usage.providerCost?.balance == 12.34)
        #expect(result.usage.providerCost?.period == "Prepaid credits")
        #expect(result.usage.identity == nil)
        #expect(request.url?.absoluteString == "https://huggingface.co/settings/billing")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/xhtml+xml")
        #expect(request.httpBody == nil)
    }

    @Test
    func `web wallet rejects login redirects wrong hosts statuses and content types`() async throws {
        let cases: [(URL, Int, String, HuggingFaceWebCreditsError)] = try [
            (
                #require(URL(string: "https://huggingface.co/login?next=%2Fsettings%2Fbilling")),
                200,
                "text/html",
                .authenticationExpired),
            (#require(URL(string: "https://example.com/settings/billing")), 200, "text/html", .invalidResponse),
            (HuggingFaceWebFetchStrategy.billingURL, 403, "text/html", .invalidResponse),
            (HuggingFaceWebFetchStrategy.billingURL, 200, "application/json", .invalidResponse),
        ]

        for (url, status, contentType, expected) in cases {
            let transport = ProviderHTTPTransportStub { _ in
                try Self.htmlResponse(url: url, body: "<html></html>", statusCode: status, contentType: contentType)
            }
            let strategy = HuggingFaceWebFetchStrategy(
                transport: transport,
                resolveCookieHeader: { _ in "session=fixture" })
            do {
                _ = try await strategy.fetch(Self.fetchContext(
                    sourceMode: .web,
                    settings: Self.manualCookieSettings()))
                Issue.record("Expected Hugging Face web response to fail")
            } catch let error as HuggingFaceWebCreditsError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected Hugging Face web error: \(error)")
            }
        }
    }

    @Test
    func `explicit web remains separate when API credentials are present`() async throws {
        let webTransport = Self.walletTransport(balance: 9.25)
        let web = HuggingFaceWebFetchStrategy(
            transport: webTransport,
            resolveCookieHeader: { _ in "session=fixture" })
        let result = try await web.fetch(Self.fetchContext(
            sourceMode: .web,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings()))

        #expect(result.strategyID == "huggingface.web")
        #expect(result.usage.providerCost?.used == 0)
        #expect(result.usage.providerCost?.balance == 9.25)
        #expect(result.usage.identity == nil)
        #expect(result.usage.details.isEmpty)
        #expect(await webTransport.requests().count == 1)
    }

    @Test
    func `auto with API keeps the API snapshot authoritative when a browser wallet is available`() async throws {
        let recorder = HuggingFaceCookieResolutionRecorder()
        let apiTransport = Self.transport()
        let webTransport = Self.walletTransport(balance: 9.25)
        let auto = HuggingFaceAutoFetchStrategy(
            apiStrategy: Self.apiStrategy(transport: apiTransport),
            webStrategy: HuggingFaceWebFetchStrategy(
                transport: webTransport,
                resolveCookieHeader: { _ in
                    await recorder.record()
                    return "session=fixture"
                }))
        let result = try await auto.fetch(Self.fetchContext(
            sourceMode: .auto,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings()))

        #expect(result.strategyID == "huggingface.js")
        #expect(result.sourceLabel == "api")
        #expect(result.usage.providerCost?.used == 2.41)
        #expect(result.usage.providerCost?.balance == nil)
        #expect(result.usage.providerCost?.period == "Reported billing period")
        #expect(result.usage.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(result.usage.identity?.accountID == "fixture-user")
        #expect(result.usage.identity?.accountEmail == "fixture@example.com")
        #expect(result.usage.details.count == 2)
        #expect(result.usage.dataConfidence == .exact)
        #expect(await recorder.count == .zero)
        #expect(await apiTransport.requests().count == 2)
        #expect(await webTransport.requests().isEmpty)
    }

    @Test
    func `auto with API never consults the browser wallet for either optional usage preference`() async throws {
        for includeOptionalUsage in [false, true] {
            let recorder = HuggingFaceCookieResolutionRecorder()
            let webTransport = Self.walletTransport(balance: 9.25)
            let auto = HuggingFaceAutoFetchStrategy(
                apiStrategy: Self.apiStrategy(transport: Self.transport()),
                webStrategy: HuggingFaceWebFetchStrategy(
                    transport: webTransport,
                    resolveCookieHeader: { _ in
                        await recorder.record()
                        return "session=fixture"
                    }))
            let result = try await auto.fetch(Self.fetchContext(
                sourceMode: .auto,
                environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
                settings: Self.manualCookieSettings(),
                includeOptionalUsage: includeOptionalUsage))

            #expect(result.usage.providerCost?.used == 2.41)
            #expect(result.usage.providerCost?.balance == nil)
            #expect(result.usage.identity?.accountID == "fixture-user")
            #expect(await recorder.count == .zero)
            #expect(await webTransport.requests().isEmpty)
        }
    }

    @Test
    func `auto with API keeps an unchanged API snapshot instead of adopting a wallet balance`() async throws {
        let recorder = HuggingFaceCookieResolutionRecorder()
        let webTransport = Self.walletTransport(balance: 0)
        let auto = HuggingFaceAutoFetchStrategy(
            apiStrategy: Self.apiStrategy(transport: Self.transport()),
            webStrategy: HuggingFaceWebFetchStrategy(
                transport: webTransport,
                resolveCookieHeader: { _ in
                    await recorder.record()
                    return "session=fixture"
                }))
        let result = try await auto.fetch(Self.fetchContext(
            sourceMode: .auto,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings()))

        #expect(result.usage.providerCost?.used == 2.41)
        #expect(result.usage.providerCost?.balance == nil)
        #expect(await recorder.count == .zero)
        #expect(await webTransport.requests().isEmpty)
    }

    @Test
    func `auto with API does not fall back to web when the API fetch fails`() async throws {
        let recorder = HuggingFaceCookieResolutionRecorder()
        let webTransport = Self.walletTransport(balance: 7.5)
        let failingAPI = ProviderHTTPTransportStub { _ in
            throw ProviderPluginError.script("fixture API outage")
        }
        let auto = HuggingFaceAutoFetchStrategy(
            apiStrategy: Self.apiStrategy(transport: failingAPI),
            webStrategy: HuggingFaceWebFetchStrategy(
                transport: webTransport,
                resolveCookieHeader: { _ in
                    await recorder.record()
                    return "session=fixture"
                }))
        let context = Self.fetchContext(
            sourceMode: .auto,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.manualCookieSettings())

        #expect(await auto.isAvailable(context))
        do {
            _ = try await auto.fetch(context)
            Issue.record("Expected the available API strategy failure to propagate")
        } catch {
            #expect(!(error is CancellationError))
        }
        #expect(await recorder.count == .zero)
        #expect(await webTransport.requests().isEmpty)
    }

    @Test
    func `auto falls back to cookie only balance when API is unavailable`() async throws {
        let cookieOnly = HuggingFaceAutoFetchStrategy(
            apiStrategy: Self.apiStrategy(transport: Self.transport()),
            webStrategy: HuggingFaceWebFetchStrategy(
                transport: Self.walletTransport(balance: 7.5),
                resolveCookieHeader: { _ in "session=fixture" }))
        let cookieOnlyContext = Self.fetchContext(
            sourceMode: .auto,
            environment: [:],
            settings: Self.manualCookieSettings())
        #expect(await cookieOnly.isAvailable(cookieOnlyContext))
        let cookieOnlyResult = try await cookieOnly.fetch(cookieOnlyContext)
        #expect(cookieOnlyResult.usage.providerCost?.used == 0)
        #expect(cookieOnlyResult.usage.providerCost?.balance == 7.5)
        #expect(cookieOnlyResult.usage.identity == nil)
    }

    @Test
    func `API mode and off mode perform zero cookie work`() async throws {
        let recorder = HuggingFaceCookieResolutionRecorder()
        let strategy = HuggingFaceWebFetchStrategy(resolveCookieHeader: { _ in
            await recorder.record()
            return "session=fixture"
        })

        do {
            _ = try await strategy.fetch(Self.fetchContext(
                sourceMode: .api,
                settings: Self.manualCookieSettings()))
            Issue.record("Expected API mode to reject the web strategy")
        } catch let error as HuggingFaceWebCreditsError {
            #expect(error == .unavailable)
        }
        #expect(await recorder.count == .zero)

        let offContext = Self.fetchContext(sourceMode: .web, settings: Self.cookieSettings(source: .off))
        #expect(await strategy.isAvailable(offContext) == false)
        do {
            _ = try await strategy.fetch(offContext)
            Issue.record("Expected off mode to reject the web strategy")
        } catch let error as HuggingFaceWebCreditsError {
            #expect(error == .unavailable)
        }
        #expect(await recorder.count == .zero)
    }

    @Test
    func `auto uses API only when the web source is off`() async throws {
        let recorder = HuggingFaceCookieResolutionRecorder()
        let auto = HuggingFaceAutoFetchStrategy(
            apiStrategy: Self.apiStrategy(transport: Self.transport()),
            webStrategy: HuggingFaceWebFetchStrategy(resolveCookieHeader: { _ in
                await recorder.record()
                return "session=fixture"
            }))
        let result = try await auto.fetch(Self.fetchContext(
            sourceMode: .auto,
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            settings: Self.cookieSettings(source: .off)))

        #expect(result.usage.providerCost?.used == 2.41)
        #expect(result.usage.providerCost?.balance == nil)
        #expect(await recorder.count == .zero)
    }

    @Test
    func `web cancellation propagates`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            throw CancellationError()
        }
        let strategy = HuggingFaceWebFetchStrategy(
            transport: transport,
            resolveCookieHeader: { _ in "session=fixture" })

        await #expect(throws: CancellationError.self) {
            _ = try await strategy.fetch(Self.fetchContext(
                sourceMode: .web,
                settings: Self.manualCookieSettings()))
        }
    }

    private static func fetchContext(
        sourceMode: ProviderSourceMode = .api,
        environment: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil,
        includeOptionalUsage: Bool = true,
        webTimeout: TimeInterval = 1) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: webTimeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: HuggingFaceTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func manualCookieSettings() -> ProviderSettingsSnapshot {
        self.cookieSettings(source: .manual, manualCookieHeader: "session=fixture")
    }

    private static func cookieSettings(
        source: ProviderCookieSource,
        manualCookieHeader: String? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot.make(huggingface: HuggingFaceProviderSettings(
            cookieSource: source,
            manualCookieHeader: manualCookieHeader))
    }

    private static func parserError(_ html: String) -> HuggingFaceWebCreditsParser.ParseError? {
        do {
            _ = try HuggingFaceWebCreditsParser.parse(html)
            return nil
        } catch let error as HuggingFaceWebCreditsParser.ParseError {
            return error
        } catch {
            Issue.record("Unexpected Hugging Face parser error: \(error)")
            return nil
        }
    }

    private static func dataProps(_ json: String) -> String {
        let encoded = json
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return #"<div class="billing" data-props="\#(encoded)"></div>"#
    }

    private static func htmlResponse(
        url: URL,
        body: String,
        statusCode: Int,
        contentType: String = "text/html; charset=utf-8") throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]))
        return (Data(body.utf8), response)
    }

    private static func walletTransport(balance: Double) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let json = #"""
            {
              "entity": {
                "type": "user",
                "name": "unverified-name",
                "user": "fixture-user",
                "currentBalanceUsd": \#(balance)
              }
            }
            """#
            return try Self.htmlResponse(
                url: url,
                body: Self.dataProps(json),
                statusCode: 200)
        }
    }

    private static func apiStrategy(transport: any ProviderHTTPTransport) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "huggingface.js",
            provider: .huggingface,
            bundledPlugin: "huggingface",
            secretKey: HuggingFaceSettingsReader.tokenEnvironmentKey,
            sourceLabel: "api",
            transport: transport,
            resolveSecret: { environment in
                HuggingFaceSettingsReader.token(environment: environment)
            },
            isEnabled: { _ in true })
    }

    private static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func billingBody(
        periodStart: String = "2026-08-01T00:00:00Z",
        periodEnd: String = "2026-09-01T00:00:00Z",
        usage: String = Self.billingUsageFixture) -> String
    {
        "{\"period\":{\"periodStart\":\"\(periodStart)\",\"periodEnd\":\"\(periodEnd)\"},\"usage\":\(usage)}"
    }

    private static func usageBody(endpoints: String, spaces: String) -> String {
        "{\"Endpoints\":\(endpoints),\"Spaces\":\(spaces)}"
    }

    private static let profileFixture = #"{"name":"fixture-user","email":"fixture@example.com","isPro":true}"#

    private static let billingUsageFixture = #"""
    {"Endpoints":[
        {"entityId":"endpoint-fixture-a","label":"Endpoint A","product":"inference-endpoints",
         "unitLabel":"compute","productPrettyName":"Endpoint","unitCostMicroUSD":100,
         "active":true,"quantity":10000,"totalCostMicroUSD":1000000,
         "startedAt":"2026-08-03T00:00:00Z","stoppedAt":"2026-08-04T00:00:00Z"},
        {"entityId":"endpoint-fixture-b","label":"Endpoint B","product":"inference-endpoints",
         "unitLabel":"compute","productPrettyName":"Endpoint","unitCostMicroUSD":100,
         "active":true,"quantity":7500,"totalCostMicroUSD":750000,
         "startedAt":"2026-08-05T00:00:00Z","stoppedAt":"2026-08-06T00:00:00Z"}],
        "Spaces":[
        {"entityId":"space-fixture","label":"Space","product":"spaces",
         "unitLabel":"compute","productPrettyName":"Space","unitCostMicroUSD":100,
         "active":false,"quantity":6600,"totalCostMicroUSD":660000,
        "startedAt":"2026-08-10T00:00:00Z","stoppedAt":"2026-08-11T00:00:00Z"}]}
    """#

    private static let billingFixture = Self.billingBody()
}

extension HuggingFaceUsageStatsTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `identity failures leave a valid billing snapshot available`(engine: ProviderPluginEngineKind) async throws {
        let cases = [
            (profileBody: #"{"error":"hf_fixture_token"}"#, profileStatus: 401),
            (profileBody: #"{"error":"hf_fixture_token"}"#, profileStatus: 503),
            (profileBody: #"{"name":123}"#, profileStatus: 200),
        ]

        for (profileBody, profileStatus) in cases {
            let snapshot = try await Self.fetch(
                engine: engine,
                profileBody: profileBody,
                profileStatus: profileStatus)
            #expect(snapshot.providerCost?.used == 2.41)
            #expect(snapshot.identity == nil)
            #expect(snapshot.detailRow(label: "Reported spend")?.value == "$2.41")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing refreshes on every fetch while identity is cached`(engine: ProviderPluginEngineKind) async throws {
        let transport = Self.transport()
        let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)
        let secrets = [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"]

        _ = try await runtime.fetchUsage(
            secrets: secrets,
            now: Date(timeIntervalSince1970: 1_777_000_000))
        let second = try await runtime.fetchUsage(
            secrets: secrets,
            now: Date(timeIntervalSince1970: 1_777_000_001))
        let requests = await transport.requests()

        #expect(second.identity?.accountID == "fixture-user")
        #expect(requests.map { $0.url?.path } == [
            "/api/settings/billing/usage",
            "/api/whoami-v2",
            "/api/settings/billing/usage",
        ])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `identity cache is isolated when the bearer token changes`(engine: ProviderPluginEngineKind) async throws {
        let transport = Self.transport()
        let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)

        _ = try await runtime.fetchUsage(
            secrets: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_first_token"],
            now: Date(timeIntervalSince1970: 1_777_000_000))
        _ = try await runtime.fetchUsage(
            secrets: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_second_token"],
            now: Date(timeIntervalSince1970: 1_777_000_001))
        let requests = await transport.requests()

        #expect(requests.map { $0.url?.path } == [
            "/api/settings/billing/usage",
            "/api/whoami-v2",
            "/api/settings/billing/usage",
            "/api/whoami-v2",
        ])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer hf_first_token",
            "Bearer hf_first_token",
            "Bearer hf_second_token",
            "Bearer hf_second_token",
        ])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failed identity refreshes are not cached`(engine: ProviderPluginEngineKind) async throws {
        let transports = [
            Self.transport(profileStatus: 503),
            Self.transport(profileBody: #"{"name":123}"#),
        ]
        let secrets = [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"]

        for transport in transports {
            let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)
            for _ in 0..<2 {
                let snapshot = try await runtime.fetchUsage(
                    secrets: secrets,
                    now: Date(timeIntervalSince1970: 1_777_000_000))
                #expect(snapshot.providerCost?.used == 2.41)
                #expect(snapshot.identity == nil)
            }
            let requests = await transport.requests()
            #expect(requests.count(where: { $0.url?.path == "/api/settings/billing/usage" }) == 2)
            #expect(requests.count(where: { $0.url?.path == "/api/whoami-v2" }) == 2)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing remains authoritative when a cached identity exists`(engine: ProviderPluginEngineKind) async throws {
        let statuses = HuggingFaceHTTPStatusSequence([200, 401])
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/settings/billing/usage":
                let status = await statuses.next()
                return try Self.response(
                    url: url,
                    body: status == 200 ? Self.billingFixture : #"{"error":"hf_fixture_token"}"#,
                    statusCode: status)
            case "/api/whoami-v2":
                return try Self.response(url: url, body: Self.profileFixture, statusCode: 200)
            default:
                throw ProviderPluginError.script("Unexpected Hugging Face fixture path: \(url.path)")
            }
        }
        let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)
        let secrets = [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"]

        _ = try await runtime.fetchUsage(
            secrets: secrets,
            now: Date(timeIntervalSince1970: 1_777_000_000))
        do {
            _ = try await runtime.fetchUsage(
                secrets: secrets,
                now: Date(timeIntervalSince1970: 1_777_000_001))
            Issue.record("Expected the second billing request to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("personal billing usage"))
        }
        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == [
            "/api/settings/billing/usage",
            "/api/whoami-v2",
            "/api/settings/billing/usage",
        ])
    }

    @Test
    func `descriptor reuses the API strategy across pipeline resolutions`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)
        let context = Self.fetchContext(
            environment: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"])
        let first = try #require(
            await descriptor.fetchPlan.pipeline.resolveStrategies(context).first as? ScriptFetchStrategy)
        let second = try #require(
            await descriptor.fetchPlan.pipeline.resolveStrategies(context).first as? ScriptFetchStrategy)

        #expect(first === second)
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        transport: ProviderHTTPTransportStub? = nil,
        profileBody: String = Self.profileFixture,
        billingBody: String = Self.billingFixture,
        profileStatus: Int = 200,
        billingStatus: Int = 200,
        profileHeaders: [String: String] = [:],
        billingHeaders: [String: String] = [:]) async throws -> UsageSnapshot
    {
        let transport = transport ?? Self.transport(
            profileBody: profileBody,
            billingBody: billingBody,
            profileStatus: profileStatus,
            billingStatus: billingStatus,
            profileHeaders: profileHeaders,
            billingHeaders: billingHeaders)
        let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)
        return try await runtime.fetchUsage(
            secrets: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            now: Date(timeIntervalSince1970: 1_777_000_000))
    }

    private static func transport(
        profileBody: String = Self.profileFixture,
        billingBody: String = Self.billingFixture,
        profileStatus: Int = 200,
        billingStatus: Int = 200,
        profileHeaders: [String: String] = [:],
        billingHeaders: [String: String] = [:]) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/whoami-v2":
                return try Self.response(
                    url: url,
                    body: profileBody,
                    statusCode: profileStatus,
                    headers: profileHeaders)
            case "/api/settings/billing/usage":
                return try Self.response(
                    url: url,
                    body: billingBody,
                    statusCode: billingStatus,
                    headers: billingHeaders)
            default:
                throw ProviderPluginError.script("Unexpected Hugging Face fixture path: \(url.path)")
            }
        }
    }

    private static func response(
        url: URL,
        body: String,
        statusCode: Int,
        headers: [String: String] = [:]) throws -> (Data, URLResponse)
    {
        var headerFields = headers
        headerFields["Content-Type"] = "application/json"
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields))
        return (Data(body.utf8), response)
    }
}

private actor HuggingFaceHTTPStatusSequence {
    private var statuses: [Int]

    init(_ statuses: [Int]) {
        self.statuses = statuses
    }

    func next() -> Int {
        if self.statuses.count > 1 {
            return self.statuses.removeFirst()
        }
        return self.statuses.first ?? 200
    }
}

@MainActor
struct HuggingFaceProviderPresentationTests {
    @Test
    func `billing spend remains visible when cost summary is disabled`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 2.41,
                limit: 0,
                currencyCode: "USD",
                period: "Reported billing period",
                resetsAt: ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"),
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .huggingface,
            metadata: HuggingFaceProviderDescriptor.descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Reported billing period: $2.41")
    }
}

@MainActor
struct HuggingFaceProviderSettingsTests {
    @Test
    func `settings expose API and cookie sources with deliberate app availability`() throws {
        let suite = "HuggingFaceProviderSettingsTests-token"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .huggingface,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})

        let implementation = HuggingFaceProviderImplementation()
        let fields = implementation.settingsFields(context: context)
        #expect(fields.count == 2)
        let field = try #require(fields.first)
        #expect(field.id == "huggingface-api-token")
        #expect(field.title == "API token")
        #expect(field.kind == .secure)
        #expect(field.placeholder == "hf_...")

        field.binding.wrappedValue = "hf_fixture_token"
        #expect(settings[providerConfig: .huggingface, field: .apiKey] == "hf_fixture_token")
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))

        let picker = try #require(implementation.settingsPickers(context: context).first)
        #expect(picker.id == "huggingface-cookie-source")
        #expect(picker.options.map(\.id) == ["auto", "manual", "off"])
        #expect(fields[1].isVisible?() == false)
        picker.binding.wrappedValue = ProviderCookieSource.manual.rawValue
        #expect(fields[1].isVisible?() == true)
        #expect(fields[1].actions.first?.id == "huggingface-open-billing")

        field.binding.wrappedValue = ""
        fields[1].binding.wrappedValue = "session=fixture"
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))

        field.binding.wrappedValue = "hf_second_fixture_token"
        #expect(settings.huggingFaceCookieSource == .manual)
        #expect(settings.huggingFaceManualCookieHeader == "session=fixture")
        field.binding.wrappedValue = ""

        fields[1].binding.wrappedValue = ""
        #expect(settings.huggingFaceCookieSource == .manual)
        #expect(settings.huggingFaceManualCookieHeader.isEmpty)
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])) == false)

        picker.binding.wrappedValue = ProviderCookieSource.auto.rawValue
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))

        picker.binding.wrappedValue = ProviderCookieSource.off.rawValue
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])) == false)
    }
}

private actor HuggingFaceCookieResolutionRecorder {
    private(set) var count = 0

    func record() {
        self.count += 1
    }
}

private struct HuggingFaceTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
