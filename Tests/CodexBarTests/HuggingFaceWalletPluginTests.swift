import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HuggingFaceWalletPluginTests {
    static let profile = #"{"type":"user","id":"opaque-a","name":"fixture-user","isPro":true}"#
    static let current = #"{"entity":{"type":"user","name":"unverified-name","currentBalanceUsd":12.345}}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `matched wallet adds credits without inventing a quota`(engine: ProviderPluginEngineKind) async throws {
        for source in [ProviderCookieSource.auto, .manual] {
            let snapshot = try await Self.fetch(engine: engine, cookieSource: source)
            #expect(snapshot.providerCost?.balance == 12.345)
            #expect(abs((snapshot.providerCost?.used ?? -1) - 0.45) < 0.000001)
            #expect(snapshot.primary == nil)
            #expect(snapshot.extraRateWindows == nil)
            #expect(snapshot.providerCost?.resetsAt == nil)
            #expect(snapshot.details.last?.title == "Credits")
            #expect(snapshot.details.last?.rows.first?.label == "Prepaid balance")
            #expect(snapshot.details.last?.rows.first?.value == "$12.35")
            #expect(snapshot.identity?.accountID == "fixture-user")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `ported wallet fixtures preserve zero legacy cents and current precedence`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixtures: [(String, Double)] = [
            (Self.props(#"{"entity":{"type":"user","currentBalanceUsd":0}}"#), 0),
            (Self.props(#"{"invoiceCreditsCents":7250}"#), 72.5),
            (Self.props(#"{"invoiceCreditsCents":7250,"entity":{"type":"user","currentBalanceUsd":8.125}}"#), 8.125),
            (Self.props(#"{"invoiceCreditsCents":null,"entity":{"type":"user","currentBalanceUsd":4.5}}"#), 4.5),
            (Self.props(#"{"kind":"navigation"}"#) + Self.props(Self.current), 12.345),
            ("<div data-props='" + Self.current + "'></div>", 12.345),
            (Self.props(Self.current).replacingOccurrences(of: "&quot;", with: "&#34;"), 12.345),
            (Self.props(Self.current).replacingOccurrences(of: "&quot;", with: "&#x22;"), 12.345),
        ]
        for (html, balance) in fixtures {
            let snapshot = try await Self.fetch(engine: engine, html: html)
            #expect(snapshot.providerCost?.balance == balance)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed ambiguous and absent wallets preserve API usage`(engine: ProviderPluginEngineKind) async throws {
        let invalid = [
            #"{"entity":{"type":"user","currentBalanceUsd":null},"invoiceCreditsCents":100}"#,
            #"{"entity":{"type":"user","currentBalanceUsd":"12.34"}}"#,
            #"{"entity":{"type":"user","currentBalanceUsd":true}}"#,
            #"{"entity":{"type":"user","currentBalanceUsd":-0.01}}"#,
            #"{"entity":{"type":"user","currentBalanceUsd":1e400}}"#,
            #"{"entity":{"type":"organization","currentBalanceUsd":12.34}}"#,
            #"{"invoiceCreditsCents":12.5}"#,
            #"{"invoiceCreditsCents":-1}"#,
            #"{"invoiceCreditsCents":9007199254740992}"#,
            #"{"invoiceCreditsCents":true}"#,
            #"{"invoiceCreditsCents":null}"#,
            #"{"invoiceCreditsCents":"100"}"#,
            #"{"invoiceCreditsCents":1e400}"#,
            #"{"entity":{"type":"user","usedNanoUsd":1234}}"#,
        ]
        let htmlCases = invalid.map(Self.props) + [
            "<div>Credits remaining: $12.34</div>",
            Self.props(Self.current) + Self.props(Self.current),
            Self.props(#"{"invoiceCreditsCents":100}"#) + Self.props(#"{"invoiceCreditsCents":200}"#),
            Self.props(Self.current).replacingOccurrences(of: "div", with: "span"),
            #"<div data-props="{&quot;entity&quot;:"></div>"#,
            Self.props(Self.current).replacingOccurrences(of: "&quot;", with: "&invalid;"),
            Self.props(Self.current).replacingOccurrences(of: "&quot;", with: "&#xD800;"),
        ]
        for html in htmlCases {
            let snapshot = try await Self.fetch(engine: engine, html: html)
            Self.expectNoWallet(snapshot)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `wallet ownership requires exact opaque user ids on both authorities`(
        engine: ProviderPluginEngineKind) async throws
    {
        let invalidProfiles = [
            #"{"type":"user","id":"opaque-b","name":"fixture-user"}"#,
            #"{"type":"org","id":"opaque-a","name":"fixture-user"}"#,
            #"{"id":"opaque-a","name":"fixture-user"}"#,
            #"{"type":"user","id":"","name":"fixture-user"}"#,
            #"{"type":"user","id":42,"name":"fixture-user"}"#,
            #"{"type":"user","name":"fixture-user"}"#,
            #"{"type":"user","id":" opaque-a ","name":"fixture-user"}"#,
        ]
        for profile in invalidProfiles {
            try await Self.expectNoWallet(Self.fetch(engine: engine, browserProfile: profile))
            try await Self.expectNoWallet(Self.fetch(engine: engine, apiProfile: profile))
        }
        let renamed = #"{"type":"user","id":"opaque-a","name":"other-display-name"}"#
        let snapshot = try await Self.fetch(engine: engine, browserProfile: renamed)
        #expect(snapshot.providerCost?.balance == 12.345)
        #expect(snapshot.identity?.accountID == "fixture-user")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `API only and cookies Off never resolve cookies or call web endpoints`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (mode, source) in [
            (ProviderSourceMode.api, ProviderCookieSource.auto), (.api, .manual), (.auto, .off),
        ] {
            try await Self.expectNoWallet(Self.fetch(engine: engine, sourceMode: mode, cookieSource: source))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable browser responses and cookie failures remain optional`(
        engine: ProviderPluginEngineKind) async throws
    {
        for status in [302, 401, 403, 429, 503] {
            try await Self.expectNoWallet(Self.fetch(engine: engine, webStatus: status))
            try await Self.expectNoWallet(Self.fetch(engine: engine, browserIdentityStatus: status))
        }
        try await Self.expectNoWallet(Self.fetch(engine: engine, cookieFails: true))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cached token identity cannot retain a wallet after browser account changes`(
        engine: ProviderPluginEngineKind) async throws
    {
        let log = HuggingFaceWalletRequestLog()
        let runtime = try Self.runtime(engine: engine, log: log, switchBrowser: true)
        let matched = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-token"],
            now: HuggingFacePluginTests.now,
            cookieResolver: { _, _ in "session=fixture" })
        let mismatched = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-token"],
            now: HuggingFacePluginTests.now.addingTimeInterval(60),
            cookieResolver: { _, _ in "session=fixture" })
        #expect(matched.providerCost?.balance == 12.345)
        Self.expectNoWallet(mismatched)
        #expect(await log.apiIdentityCount == 1)
        #expect(await log.browserIdentityCount == 2)
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        html: String = Self.props(Self.current),
        apiProfile: String = Self.profile,
        browserProfile: String = Self.profile,
        sourceMode: ProviderSourceMode = .auto,
        cookieSource: ProviderCookieSource = .auto,
        webStatus: Int = 200,
        browserIdentityStatus: Int = 200,
        cookieFails: Bool = false) async throws -> UsageSnapshot
    {
        let allowed = sourceMode == .auto && cookieSource != .off
        let runtime = try Self.runtime(
            engine: engine,
            html: html,
            apiProfile: apiProfile,
            browserProfile: browserProfile,
            webStatus: webStatus,
            browserIdentityStatus: browserIdentityStatus,
            webAllowed: allowed)
        return try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-token"],
            now: HuggingFacePluginTests.now,
            sourceMode: sourceMode,
            cookieSource: cookieSource,
            cookieResolver: { provider, domain in
                #expect(allowed)
                #expect(provider == .huggingface)
                #expect(domain == "huggingface.co")
                if cookieFails { throw URLError(.userAuthenticationRequired) }
                return "session=fixture"
            })
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        html: String = Self.props(Self.current),
        apiProfile: String = Self.profile,
        browserProfile: String = Self.profile,
        webStatus: Int = 200,
        browserIdentityStatus: Int = 200,
        webAllowed: Bool = true,
        log: HuggingFaceWalletRequestLog = HuggingFaceWalletRequestLog(),
        switchBrowser: Bool = false) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "huggingface",
            engine: engine,
            transport: ProviderHTTPTransportHandler { req in
                let isWeb = req.value(forHTTPHeaderField: "Cookie") != nil
                await log.record(req)
                #expect(req.value(forHTTPHeaderField: "Authorization") == (isWeb ? nil : "Bearer fixture-token"))
                if isWeb {
                    #expect(webAllowed)
                    #expect(req.value(forHTTPHeaderField: "Cookie") == "session=fixture")
                }
                let browserChanged = await log.browserIdentityCount > 1
                let body: String
                var code = 200
                switch req.url?.path {
                case "/api/settings/billing/usage-v2":
                    #expect(!isWeb)
                    body = HuggingFacePluginTests.billing
                case "/api/spaces/zero-gpu/quota":
                    #expect(!isWeb)
                    body = HuggingFacePluginTests.gpu
                case "/settings/billing":
                    #expect(isWeb)
                    code = webStatus
                    body = html
                case "/api/whoami-v2":
                    code = isWeb ? browserIdentityStatus : 200
                    body = isWeb
                        ? (switchBrowser && browserChanged
                            ? browserProfile.replacingOccurrences(of: "opaque-a", with: "opaque-b") : browserProfile)
                        : apiProfile
                default:
                    Issue.record("Unexpected Hugging Face request")
                    body = "{}"
                }
                let url = try #require(req.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": req.url?
                        .path == "/settings/billing" ? "text/html" : "application/json"]))
                return (Data(body.utf8), response)
            })
    }

    private static func expectNoWallet(_ snapshot: UsageSnapshot) {
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.details.allSatisfy { $0.title != "Credits" })
        #expect(abs((snapshot.providerCost?.used ?? -1) - 0.45) < 0.000001)
    }

    private static func props(_ json: String) -> String {
        let encoded = json.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<div data-props=\"\(encoded)\"></div>"
    }
}

private actor HuggingFaceWalletRequestLog {
    private(set) var apiIdentityCount = 0
    private(set) var browserIdentityCount = 0

    func record(_ request: URLRequest) {
        guard request.url?.path == "/api/whoami-v2" else { return }
        if request.value(forHTTPHeaderField: "Cookie") == nil {
            self.apiIdentityCount += 1
        } else {
            self.browserIdentityCount += 1
        }
    }
}
