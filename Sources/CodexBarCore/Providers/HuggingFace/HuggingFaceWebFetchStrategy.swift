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
        guard let normalizedCookie = try await Self.normalizedCookie(
            resolve: self.resolveCookieHeader,
            context: context)
        else {
            throw HuggingFaceWebCreditsError.invalidCookie
        }

        let wallet = try await self.walletSnapshot(cookieHeader: normalizedCookie, context: context)

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

    /// Resolves and normalizes the browser cookie exactly once per wallet unit of work so the
    /// billing-page request and the browser identity probe share one cookie resolution.
    static func normalizedCookie(
        resolve: CookieHeaderResolver,
        context: ProviderFetchContext) async throws -> String?
    {
        guard let normalizedCookie = try await CookieHeaderNormalizer.normalize(resolve(context)) else {
            return nil
        }
        return normalizedCookie
    }

    /// Authenticated billing-page wallet request shared by explicit Web mode and the Auto
    /// batch scope. Explicit Web mode keeps returning an identity-less, balance-only snapshot;
    /// the Auto scope layers the browser identity probe on top of the same normalized cookie.
    func walletSnapshot(
        cookieHeader: String,
        context: ProviderFetchContext) async throws -> HuggingFaceWalletSnapshot
    {
        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.1, context.webTimeout)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
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
        return HuggingFaceWalletSnapshot(balanceUSD: wallet.balanceUSD, observedAt: Date())
    }

    /// Builds the batch-scoped wallet observation unit: one cookie resolution, one billing-page
    /// request, and (only after a successful wallet fetch) one browser identity probe. The cookie
    /// header is used transiently inside this closure and never retained by the scope.
    func makeObservationFetcher(
        identityService: HuggingFaceIdentityService) -> HuggingFaceWalletBatchScope.ObservationFetcher
    {
        { context in
            let normalizedCookie = try await Self.propagatingCancellation {
                try await Self.normalizedCookie(resolve: self.resolveCookieHeader, context: context)
            }
            guard let normalizedCookie else {
                throw HuggingFaceWebCreditsError.invalidCookie
            }
            let wallet = try await Self.propagatingCancellation {
                try await self.walletSnapshot(cookieHeader: normalizedCookie, context: context)
            }
            var identity: HuggingFaceIdentity?
            do {
                identity = try await identityService.identity(
                    cookieHeader: normalizedCookie,
                    timeout: context.webTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                identity = nil
            }
            return HuggingFaceBrowserWalletObservation(wallet: wallet, identity: identity)
        }
    }

    static func propagatingCancellation<Value>(
        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}

/// Auto fetch for Hugging Face.
///
/// API billing stays the authoritative spend source. The browser-session wallet is required
/// auxiliary product data whenever browser access is safely available — independent of
/// `includeOptionalUsage`. After a successful wallet fetch, the shared batch scope's browser
/// identity is compared with this credential's bearer identity (cached by the identity service,
/// so Auto never issues a second bearer whoami for matching):
///
/// * Local exact match → provisional composition (`balanceUpdatedAt` carries the browser
///   observation time). In a true single-account scope a local match composes directly; in a
///   stacked batch the store-level post-pass decides global uniqueness.
/// * Mismatch or unverifiable identity → fail closed: the API snapshot stays unmodified and the
///   wallet is published once at provider level as unverified.
struct HuggingFaceAutoFetchStrategy: ProviderFetchStrategy {
    let id: String = "huggingface.js"
    let kind: ProviderFetchKind = .apiToken

    private let apiStrategy: ScriptFetchStrategy
    private let webStrategy: HuggingFaceWebFetchStrategy
    private let identityService: HuggingFaceIdentityService

    init(
        apiStrategy: ScriptFetchStrategy,
        webStrategy: HuggingFaceWebFetchStrategy,
        identityService: HuggingFaceIdentityService = .shared)
    {
        self.apiStrategy = apiStrategy
        self.webStrategy = webStrategy
        self.identityService = identityService
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if await self.apiStrategy.isAvailable(context) {
            return true
        }
        return await self.webStrategy.isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard await self.apiStrategy.isAvailable(context) else {
            // Cookie-only Auto: no API credential, so the wallet is the whole snapshot and
            // stays identity-less.
            return try await self.webStrategy.fetch(context)
        }
        return try await self.fetchAPIWithWallet(context)
    }

    private func fetchAPIWithWallet(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var result = try await self.apiStrategy.fetch(context)

        // Normal API behavior: display identity enrichment is best-effort and independent of the
        // browser wallet. The cached identity is reused verbatim for matching below, so Auto never
        // issues a second bearer whoami for the same credential.
        var bearerIdentity: HuggingFaceIdentity?
        if let token = HuggingFaceSettingsReader.token(environment: context.env) {
            do {
                bearerIdentity = try await self.identityService.identity(
                    bearerToken: token,
                    timeout: context.webTimeout)
                if let display = bearerIdentity?.displayIdentitySnapshot(provider: .huggingface) {
                    result = result.replacingUsage(result.usage.withIdentity(display))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                bearerIdentity = nil
            }
        }

        guard Self.walletEligible(context) else {
            return result.replacingWalletOutcome(.notAttempted)
        }

        let scope = context.huggingFaceWalletBatchScope ?? HuggingFaceWalletBatchScope()
        let observation: HuggingFaceBrowserWalletObservation
        do {
            observation = try await scope.observation(
                for: context,
                fetcher: self.webStrategy.makeObservationFetcher(identityService: self.identityService))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Attempted and failed: the store clears any prior provider-level wallet so stale
            // Credits never outlive a proven-unavailable browser session.
            return result.replacingWalletOutcome(.unavailable)
        }

        if let browserIdentity = observation.identity,
           let bearerIdentity,
           bearerIdentity.opaqueUserID == browserIdentity.opaqueUserID
        {
            // Local exact match. `balanceUpdatedAt` carries the browser observation time.
            let composed = Self.composingWallet(
                in: result.usage,
                balanceUSD: observation.wallet.balanceUSD,
                observedAt: observation.wallet.observedAt)
            return result
                .replacingUsage(composed)
                .replacingSourceLabel("api+web")
                .replacingWalletOutcome(.localMatchComposed(
                    balanceUSD: observation.wallet.balanceUSD,
                    observedAt: observation.wallet.observedAt))
        }

        // Mismatch or unverifiable identity: fail closed for composition, never for visibility.
        // The API snapshot stays unmodified; the wallet surfaces once at provider level.
        return result.replacingWalletOutcome(.providerLevel(HuggingFaceBrowserWalletPublication(
            balanceUSD: observation.wallet.balanceUSD,
            observedAt: observation.wallet.observedAt,
            attribution: .unverified)))
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func walletEligible(_ context: ProviderFetchContext) -> Bool {
        HuggingFaceBrowserWalletPolicy.isWalletEligible(context)
    }

    static func composingWallet(
        in usage: UsageSnapshot,
        balanceUSD: Double,
        observedAt: Date) -> UsageSnapshot
    {
        guard let cost = usage.providerCost else { return usage }
        return usage.with(providerCost: cost.replacing(balance: balanceUSD, balanceUpdatedAt: observedAt))
    }
}

extension ProviderFetchResult {
    public func replacingWalletOutcome(
        _ outcome: HuggingFaceBrowserWalletOutcome?) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: self.usage,
            credits: self.credits,
            dashboard: self.dashboard,
            sourceLabel: self.sourceLabel,
            strategyID: self.strategyID,
            strategyKind: self.strategyKind,
            codexResetCreditsAttempted: self.codexResetCreditsAttempted,
            codexMonthlyLimitEnrichmentFailed: self.codexMonthlyLimitEnrichmentFailed,
            diagnostic: self.diagnostic,
            claudeOAuthKeychainPersistentRefHash: self.claudeOAuthKeychainPersistentRefHash,
            claudeOAuthHistoryOwnerIdentifier: self.claudeOAuthHistoryOwnerIdentifier,
            claudeOAuthCredentialOwner: self.claudeOAuthCredentialOwner,
            claudeOAuthKeychainCredentialMismatch: self.claudeOAuthKeychainCredentialMismatch,
            claudeOAuthKeychainCredentialAbsent: self.claudeOAuthKeychainCredentialAbsent,
            claudeOAuthKeychainCredentialUnavailable: self.claudeOAuthKeychainCredentialUnavailable,
            huggingFaceWalletOutcome: outcome)
    }

    public func replacingSourceLabel(_ sourceLabel: String) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: self.usage,
            credits: self.credits,
            dashboard: self.dashboard,
            sourceLabel: sourceLabel,
            strategyID: self.strategyID,
            strategyKind: self.strategyKind,
            codexResetCreditsAttempted: self.codexResetCreditsAttempted,
            codexMonthlyLimitEnrichmentFailed: self.codexMonthlyLimitEnrichmentFailed,
            diagnostic: self.diagnostic,
            claudeOAuthKeychainPersistentRefHash: self.claudeOAuthKeychainPersistentRefHash,
            claudeOAuthHistoryOwnerIdentifier: self.claudeOAuthHistoryOwnerIdentifier,
            claudeOAuthCredentialOwner: self.claudeOAuthCredentialOwner,
            claudeOAuthKeychainCredentialMismatch: self.claudeOAuthKeychainCredentialMismatch,
            claudeOAuthKeychainCredentialAbsent: self.claudeOAuthKeychainCredentialAbsent,
            claudeOAuthKeychainCredentialUnavailable: self.claudeOAuthKeychainCredentialUnavailable,
            huggingFaceWalletOutcome: self.huggingFaceWalletOutcome)
    }
}
