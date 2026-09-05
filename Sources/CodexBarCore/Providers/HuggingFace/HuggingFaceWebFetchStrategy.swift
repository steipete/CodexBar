import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HuggingFaceWebCreditsError: Error, Equatable, Sendable {
    case unavailable
    case invalidCookie
    case invalidResponse
    case authenticationExpired
    case parseFailure
}

struct HuggingFaceWebFetchStrategy: ProviderFetchStrategy {
    typealias CookieHeaderResolver = @Sendable (ProviderFetchContext) async throws -> String

    let id: String = "huggingface.web"
    let kind: ProviderFetchKind = .web

    private let transport: any ProviderHTTPTransport
    private let resolveCookieHeader: CookieHeaderResolver

    init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        resolveCookieHeader: @escaping CookieHeaderResolver = { context in
            try await ProviderPluginCookieBroker.resolver(context: context)(.huggingface, Self.host)
        })
    {
        self.transport = transport
        self.resolveCookieHeader = resolveCookieHeader
    }

    static let billingURL = URL(string: "https://huggingface.co/settings/billing")!
    private static let host = "huggingface.co"

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode != .api else { return false }
        let source = context.settings?.huggingface?.cookieSource ?? .auto
        guard source != .off else { return false }
        if source == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.huggingface?.manualCookieHeader) != nil
        }

        // Availability checks inspect configuration only. The shared broker resolves cached cookies before any
        // prompt-free browser import when fetch actually runs.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.sourceMode != .api else {
            throw HuggingFaceWebCreditsError.unavailable
        }
        guard context.settings?.huggingface?.cookieSource != .off else {
            throw HuggingFaceWebCreditsError.unavailable
        }
        guard let normalizedCookie = try await CookieHeaderNormalizer.normalize(self.resolveCookieHeader(context))
        else {
            throw HuggingFaceWebCreditsError.invalidCookie
        }

        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.1, context.webTimeout)
        request.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let response = try await self.transport.response(for: request)
        guard let finalURL = response.response.url,
              finalURL.scheme?.lowercased() == "https",
              finalURL.host?.lowercased() == Self.host
        else {
            throw HuggingFaceWebCreditsError.invalidResponse
        }
        if finalURL.path == "/login" || finalURL.path.hasPrefix("/login/") {
            throw HuggingFaceWebCreditsError.authenticationExpired
        }
        guard response.statusCode == 200 else {
            throw HuggingFaceWebCreditsError.invalidResponse
        }
        guard response.response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/html") == true
        else {
            throw HuggingFaceWebCreditsError.invalidResponse
        }
        guard let html = String(data: response.data, encoding: .utf8) else {
            throw HuggingFaceWebCreditsError.parseFailure
        }

        let wallet: HuggingFaceWebCreditsSnapshot
        do {
            wallet = try HuggingFaceWebCreditsParser.parseSnapshot(html)
        } catch HuggingFaceWebCreditsParser.ParseError.unavailable {
            throw HuggingFaceWebCreditsError.unavailable
        } catch {
            throw HuggingFaceWebCreditsError.parseFailure
        }

        let now = Date()
        let cost = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Prepaid credits",
            balance: wallet.balanceUSD,
            updatedAt: now)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: now,
            identity: nil)
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct HuggingFaceAutoFetchStrategy: ProviderFetchStrategy {
    let id: String = "huggingface.js"
    let kind: ProviderFetchKind = .apiToken

    private let apiStrategy: ScriptFetchStrategy
    private let webStrategy: HuggingFaceWebFetchStrategy

    init(apiStrategy: ScriptFetchStrategy, webStrategy: HuggingFaceWebFetchStrategy) {
        self.apiStrategy = apiStrategy
        self.webStrategy = webStrategy
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if await self.apiStrategy.isAvailable(context) {
            return true
        }
        return await self.webStrategy.isAvailable(context)
    }

    /// Auto fetches from exactly one authority per refresh: bearer-token billing when an API credential is
    /// available, and otherwise the browser-session wallet. An independently authenticated browser wallet is never
    /// composed into an API billing snapshot because Hugging Face exposes no shared account identifier across both
    /// authentication paths. `includeOptionalUsage` therefore never re-enables web access once API availability wins.
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        if await self.apiStrategy.isAvailable(context) {
            return try await self.apiStrategy.fetch(context)
        }
        return try await self.webStrategy.fetch(context)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
