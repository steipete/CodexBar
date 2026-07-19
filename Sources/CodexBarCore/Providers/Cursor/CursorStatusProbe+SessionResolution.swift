import Foundation

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    private struct CachedSessionFetchContext<Value: Sendable> {
        let cookieHeaderOverride: String?
        let allowAppAuthFallback: Bool
        let logger: ((String) -> Void)?
        let log: (String) -> Void
        let perform: @Sendable (String, String?) async throws -> Value
    }

    private enum CachedSessionFetchResult<Value> {
        case succeeded(Value)
        case resumeFallback
    }

    /// Resolve a working Cursor session, preserving selected-account and cache-ownership rules.
    func resolveSession<Value: Sendable>(
        cookieHeaderOverride: String? = nil,
        allowCachedSessions: Bool = true,
        allowAppAuthFallback: Bool = true,
        logger: ((String) -> Void)? = nil,
        perform: @escaping @Sendable (
            _ cookieHeader: String,
            _ requestUsageUserIDFallback: String?) async throws -> Value)
        async throws -> Value
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var firstRecoverableError: CursorStatusProbeError?

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await perform(override, nil)
        }

        // A browser fallback started by this refresh must not overwrite a concurrently committed login.
        var cacheObservation = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(provider: .cursor),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let context = CachedSessionFetchContext(
                cookieHeaderOverride: cookieHeaderOverride,
                allowAppAuthFallback: allowAppAuthFallback,
                logger: logger,
                log: log,
                perform: perform)
            switch try await self.fetchCachedSession(cached, context: context) {
            case let .succeeded(value):
                return value
            case .resumeFallback:
                #if os(macOS)
                cacheObservation = cacheObservation.afterOwnedClear()
                #endif
            }
        }

        #if os(macOS)
        let browserCandidates = self.browserCookieImportOrder.cookieImportCandidates(using: self.browserDetection)
        switch try await self.scanResolvedBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                try await self.resolveImportedSession(
                    session,
                    perform: perform,
                    log: log,
                    cacheObservation: cacheObservation)
            })
        {
        case let .succeeded(value):
            return value
        case .exhausted:
            break
        }

        switch try await self.scanResolvedBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importDomainCookieSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                try await self.resolveImportedSession(
                    session,
                    perform: perform,
                    log: log,
                    cacheObservation: cacheObservation)
            })
        {
        case let .succeeded(value):
            return value
        case .exhausted:
            break
        }
        #endif

        if allowCachedSessions,
           let value = try await self.fetchStoredSession(
               perform: perform,
               log: log,
               cacheObservation: cacheObservation)
        {
            return value
        }

        // Transient errors for an explicit session must not silently switch accounts.
        if let firstRecoverableError {
            throw firstRecoverableError
        }

        if allowAppAuthFallback,
           let appSession = try? self.appAuthStore.loadSession(),
           appSession.isUsable
        {
            log("Using Cursor.app local auth fallback")
            let cookieHeader = try appSession.cookieHeader()
            let fetchedValue: Value?
            do {
                fetchedValue = try await perform(cookieHeader, appSession.userID())
            } catch let error as CursorStatusProbeError {
                fetchedValue = nil
                if case .notLoggedIn = error {
                    log("Cursor.app local auth was rejected")
                } else {
                    firstRecoverableError = firstRecoverableError ?? error
                }
            } catch {
                fetchedValue = nil
                firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
            }
            if let fetchedValue {
                #if os(macOS)
                let context = ResolvedSessionReconciliationContext(
                    cookieHeader: cookieHeader,
                    sourceLabel: "Cursor.app local auth",
                    cacheObservation: cacheObservation,
                    perform: perform,
                    log: log)
                return try await self.reconcileResolvedSession(value: fetchedValue, context: context)
                #else
                return fetchedValue
                #endif
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }
        throw CursorStatusProbeError.noSessionCookie
    }

    private func fetchStoredSession<Value: Sendable>(
        perform: @escaping @Sendable (String, String?) async throws -> Value,
        log: @escaping (String) -> Void,
        cacheObservation: CookieHeaderCache.ConditionalMutationObservation) async throws -> Value?
    {
        let storedCookies = await CursorSessionStore.shared.getCookies()
        guard !storedCookies.isEmpty else { return nil }

        log("Using stored session cookies")
        let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let value: Value
        do {
            value = try await perform(cookieHeader, nil)
        } catch let error as CursorStatusProbeError {
            if case .notLoggedIn = error {
                await CursorSessionStore.shared.clearCookies()
                log("Stored session invalid, cleared")
                return nil
            }
            log("Stored session failed: \(error.localizedDescription)")
            throw error
        } catch {
            log("Stored session failed: \(error.localizedDescription)")
            throw CursorStatusProbeError.networkError(error.localizedDescription)
        }

        #if os(macOS)
        let context = ResolvedSessionReconciliationContext(
            cookieHeader: cookieHeader,
            sourceLabel: "Stored Cursor session",
            cacheObservation: cacheObservation,
            perform: perform,
            log: log)
        return try await self.reconcileResolvedSession(value: value, context: context)
        #else
        return value
        #endif
    }

    private func fetchCachedSession<Value: Sendable>(
        _ cached: CookieHeaderCache.Entry,
        context: CachedSessionFetchContext<Value>) async throws -> CachedSessionFetchResult<Value>
    {
        context.log("Using cached cookie header from \(cached.sourceLabel)")
        do {
            return try await .succeeded(context.perform(cached.cookieHeader, nil))
        } catch let error as CursorStatusProbeError {
            guard case .notLoggedIn = error else { throw error }
            if let replacement = CookieHeaderCache.load(provider: .cursor), replacement != cached {
                if cached.authenticationFailurePolicy == .stopFallback,
                   replacement.authenticationFailurePolicy != .stopFallback
                {
                    context.log("Selected cached session was rejected; ignoring an unselected cache replacement")
                    throw error
                }
                context.log("Cached session changed while its request was in flight; retrying replacement")
                return try await .succeeded(self.resolveSession(
                    cookieHeaderOverride: context.cookieHeaderOverride,
                    allowCachedSessions: true,
                    allowAppAuthFallback: context.allowAppAuthFallback,
                    logger: context.logger,
                    perform: context.perform))
            }
            if cached.authenticationFailurePolicy == .stopFallback {
                context.log("Selected cached session was rejected; refusing automatic account fallback")
                throw error
            }
            guard CookieHeaderCache.clearIfCurrent(provider: .cursor, expected: cached) else {
                if let replacement = CookieHeaderCache.load(provider: .cursor), replacement != cached {
                    context.log("Cached session changed before stale-session cleanup; retrying replacement")
                    return try await .succeeded(self.resolveSession(
                        cookieHeaderOverride: context.cookieHeaderOverride,
                        allowCachedSessions: true,
                        allowAppAuthFallback: context.allowAppAuthFallback,
                        logger: context.logger,
                        perform: context.perform))
                }
                throw error
            }
            return .resumeFallback
        }
    }
}
#endif
