import Foundation

struct XAIWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "xai.web"
    let kind: ProviderFetchKind = .web

    static let missingCookieMessage =
        "Sign in to grok.com in Chrome, paste a SuperGrok cookie header, or add an OAuth token."
    static let webKeyExchangeMessage =
        "grok.com billing no longer accepts cookie-only sign-in for this endpoint. "
            + "Paste a SuperGrok OAuth token in xAI settings."

    static func canImportBrowserCookies(context: ProviderFetchContext) -> Bool {
        context.sourceMode == .web
            || context.runtime == .app
            || ProviderInteractionContext.current == .userInitiated
            || context.env["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT"] == "1"
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let settings = context.settings?.xai
        if settings?.cookieSource == .off { return false }
        if context.sourceMode == .web { return true }
        if CookieHeaderNormalizer.normalize(settings?.manualCookieHeader) != nil {
            return true
        }
        #if os(macOS)
        if CookieHeaderCache.load(provider: .xai) != nil {
            return true
        }
        if Self.canImportBrowserCookies(context: context),
           XAICookieImporter.hasSession(browserDetection: context.browserDetection)
        {
            return true
        }
        #endif
        return false
    }

    static func shouldContinueToCookies(afterOAuthUsage usage: UsageSnapshot) -> Bool {
        usage.primary == nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var identityOnlyOAuth: UsageSnapshot?
        if let token = XAISettingsReader.oauthAccessToken(
            environment: context.env,
            settings: context.settings?.xai)
        {
            do {
                let credits = try await XAIOAuthCreditsFetcher.fetch(accessToken: token)
                let usage = XAIOAuthUsageMapper.usageSnapshot(credits: credits)
                if Self.shouldContinueToCookies(afterOAuthUsage: usage) {
                    identityOnlyOAuth = usage
                } else {
                    return self.makeResult(usage: usage, sourceLabel: "oauth")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // Cookie/WKE path remains available when the CLI proxy rejects the bearer.
            }
        }

        let settings = context.settings?.xai
        if settings?.cookieSource == .off {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: Self.missingCookieMessage)
        }

        if let manual = CookieHeaderNormalizer.normalize(settings?.manualCookieHeader) {
            do {
                return try await self.fetchCookieHeader(manual)
            } catch {
                if settings?.cookieSource == .manual { throw error }
            }
        }

        #if os(macOS)
        return try await self.fetchMacOSCookies(
            context: context,
            identityOnlyOAuth: identityOnlyOAuth)
        #else
        if let identityOnlyOAuth {
            return self.makeResult(usage: identityOnlyOAuth, sourceLabel: "oauth")
        }
        throw ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: Self.missingCookieMessage)
        #endif
    }

    #if os(macOS)
    private func fetchMacOSCookies(
        context: ProviderFetchContext,
        identityOnlyOAuth: UsageSnapshot?) async throws -> ProviderFetchResult
    {
        var cacheObservation = CookieHeaderCache.observeForConditionalMutation(provider: .xai)
        if let cached = cacheObservation.entry {
            do {
                return try await self.fetchCookieHeader(cached.cookieHeader)
            } catch {
                guard Self.isAuthenticationFailure(error) else { throw error }
                if CookieHeaderCache.clearIfCurrent(provider: .xai, expected: cached) {
                    cacheObservation = cacheObservation.afterOwnedClear()
                }
            }
        }

        if let imported = try await self.fetchImportedBrowserCookies(
            context: context,
            cacheObservation: cacheObservation)
        {
            return imported
        }

        if let persisted = CookieHeaderCache.loadPersisted(provider: .xai)?.cookieHeader {
            do {
                return try await self.fetchCookieHeader(persisted)
            } catch {
                guard Self.isAuthenticationFailure(error) else { throw error }
            }
        }

        if let identityOnlyOAuth {
            return self.makeResult(usage: identityOnlyOAuth, sourceLabel: "oauth")
        }
        throw ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: Self.missingCookieMessage)
    }

    private func fetchImportedBrowserCookies(
        context: ProviderFetchContext,
        cacheObservation: CookieHeaderCache.ConditionalMutationObservation) async throws -> ProviderFetchResult?
    {
        guard Self.canImportBrowserCookies(context: context) else { return nil }
        do {
            let sessions = try XAICookieImporter.importSessions(
                browserDetection: context.browserDetection)
            var lastError: Error?
            for session in sessions {
                do {
                    let result = try await self.fetchCookieHeader(session.cookieHeader)
                    CookieHeaderCache.storeIfObservationCurrent(
                        provider: .xai,
                        expected: cacheObservation,
                        cookieHeader: session.cookieHeader,
                        sourceLabel: session.sourceLabel)
                    return result
                } catch {
                    lastError = error
                }
            }
            if let lastError, !Self.isAuthenticationFailure(lastError) {
                throw lastError
            }
        } catch {
            guard Self.isAuthenticationFailure(error) || error is ProviderFetchClassifiedError else {
                throw error
            }
        }
        return nil
    }
    #endif

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        (context.sourceMode == .auto || context.sourceMode == .web)
            && !(error is CancellationError)
    }

    private func fetchCookieHeader(_ cookieHeader: String) async throws
        -> ProviderFetchResult
    {
        do {
            let snapshot = try await GrokWebBillingFetcher.fetch(cookieHeader: cookieHeader)
            return self.makeResult(
                usage: XAIOAuthUsageMapper.usageSnapshot(
                    credits: XAIOAuthCreditsSnapshot(
                        usedPercent: snapshot.usedPercent,
                        resetsAt: snapshot.resetsAt)),
                sourceLabel: "web")
        } catch let error as GrokWebBillingError {
            throw Self.classified(error)
        }
    }

    private static func classified(_ error: GrokWebBillingError) -> ProviderFetchClassifiedError {
        switch error {
        case .missingCredentials:
            ProviderFetchClassifiedError(kind: .missingCredential, message: self.missingCookieMessage)
        case let .rpcFailed(status, message)
            where GrokWebBillingError.isWebKeyExchangeCredentialRejection(status: status, message: message):
            ProviderFetchClassifiedError(kind: .authenticationExpired, message: Self.webKeyExchangeMessage)
        case let .requestFailed(status, _) where status == 401 || status == 403:
            ProviderFetchClassifiedError(
                kind: .authenticationExpired,
                message: XAIOAuthCreditsFetcher.expiredTokenMessage)
        case let .rpcFailed(status, message)
            where GrokWebBillingError.isAuthenticationFailure(status: status, message: message):
            ProviderFetchClassifiedError(
                kind: .authenticationExpired,
                message: XAIOAuthCreditsFetcher.expiredTokenMessage)
        case .parseFailed, .emptyResponse, .invalidResponse:
            ProviderFetchClassifiedError(
                kind: .parseFailure,
                message: error.localizedDescription)
        case .teamUsageUnsupported:
            ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: "SuperGrok team usage is unavailable from the current billing surface.")
        default:
            ProviderFetchClassifiedError(kind: .apiFailure, message: error.localizedDescription)
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let classified = error as? ProviderFetchClassifiedError else { return false }
        return classified.kind == .authenticationExpired
    }
}
