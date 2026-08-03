import Foundation

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    private struct CachedSessionFetchContext<Value: Sendable> {
        let cookieHeaderOverride: String?
        let allowAppAuthFallback: Bool
        let logger: ((String) -> Void)?
        let log: (String) -> Void
        let perform: @Sendable (String, CursorSessionIdentity?) async throws -> Value
    }

    private enum CachedSessionFetchResult<Value> {
        case succeeded(Value)
        case resumeFallback
    }

    private struct AppSessionFetchContext<Value: Sendable> {
        let cachedEntry: CookieHeaderCache.Entry?
        let storedCookies: [HTTPCookie]
        let cacheObservation: CookieHeaderCache.ConditionalMutationObservation
        let perform: @Sendable (String, CursorSessionIdentity?) async throws -> Value
        let log: (String) -> Void
    }

    private enum AppSessionFetchResult<Value> {
        case succeeded(Value)
        case resumeFallback(storedCookies: [HTTPCookie])
    }

    /// Resolve a working Cursor session, preserving selected-account and cache-ownership rules.
    func resolveSession<Value: Sendable>(
        cookieHeaderOverride: String? = nil,
        allowCachedSessions: Bool = true,
        allowAppAuthFallback: Bool = true,
        logger: ((String) -> Void)? = nil,
        perform: @escaping @Sendable (
            _ cookieHeader: String,
            _ identityFallback: CursorSessionIdentity?) async throws -> Value)
        async throws -> Value
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await perform(override, nil)
        }

        // A browser fallback started by this refresh must not overwrite a concurrently committed login.
        var cacheObservation = CookieHeaderCache.observeForConditionalMutation(provider: .cursor)
        let cachedEntry = allowCachedSessions ? CookieHeaderCache.load(provider: .cursor) : nil
        var storedCookies = allowCachedSessions ? await CursorSessionStore.shared.getCookies() : []
        if !allowAppAuthFallback {
            storedCookies.removeAll(where: CursorAppAuthSession.isPersistedCookie)
        }

        if allowAppAuthFallback {
            let context = AppSessionFetchContext(
                cachedEntry: cachedEntry,
                storedCookies: storedCookies,
                cacheObservation: cacheObservation,
                perform: perform,
                log: log)
            switch try await self.fetchPreferredAppSession(context: context) {
            case let .succeeded(value):
                return value
            case let .resumeFallback(updatedStoredCookies):
                storedCookies = updatedStoredCookies
            }
        }

        if allowCachedSessions,
           let cached = cachedEntry,
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            if cached.sourceLabel == Self.appAuthSourceLabel {
                if CookieHeaderCache.clearIfCurrent(provider: .cursor, expected: cached) {
                    #if os(macOS)
                    cacheObservation = cacheObservation.afterOwnedClear()
                    #endif
                }
            } else {
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
               storedCookies: storedCookies,
               perform: perform,
               log: log,
               cacheObservation: cacheObservation)
        {
            return value
        }
        throw CursorStatusProbeError.noSessionCookie
    }

    private func fetchStoredSession<Value: Sendable>(
        storedCookies: [HTTPCookie],
        perform: @escaping @Sendable (String, CursorSessionIdentity?) async throws -> Value,
        log: @escaping (String) -> Void,
        cacheObservation: CookieHeaderCache.ConditionalMutationObservation) async throws -> Value?
    {
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

    private static let appAuthSourceLabel = "Cursor.app local auth"

    private func fetchPreferredAppSession<Value: Sendable>(
        context: AppSessionFetchContext<Value>) async throws -> AppSessionFetchResult<Value>
    {
        let loadedAppSession: CursorAppAuthSession?
        do {
            loadedAppSession = try self.appAuthStore.loadSession()
        } catch {
            loadedAppSession = nil
            context.log("Cursor.app local auth read failed: \(error.localizedDescription)")
        }

        // A session read directly from Cursor owns freshness. Only use CodexBar's persisted copy when the
        // Cursor database has no session at all; an expired app session must fall through to browser cookies.
        let persistedAppSession: CursorAppAuthSession? = if loadedAppSession == nil {
            Self.persistedAppSession(cachedEntry: context.cachedEntry, storedCookies: context.storedCookies)
        } else {
            nil
        }
        guard let appSession = loadedAppSession ?? persistedAppSession else {
            return .resumeFallback(storedCookies: context.storedCookies)
        }
        guard appSession.isUsable else {
            if loadedAppSession != nil {
                context.log("Cursor.app local auth is expired or invalid; falling back to browser cookies")
            }
            let storedCookies = Self.removingAppSession(appSession, from: context.storedCookies)
            await CursorSessionStore.shared.setCookies(storedCookies)
            return .resumeFallback(storedCookies: storedCookies)
        }

        let appIdentity = appSession.identity
        Self.logIdentityMismatchIfNeeded(
            appIdentity: appIdentity,
            cachedEntry: context.cachedEntry,
            storedCookies: context.storedCookies,
            log: context.log)
        context.log("Using Cursor.app local auth")
        let cookieHeader = try appSession.cookieHeader()
        do {
            let value = try await context.perform(cookieHeader, appIdentity)
            await self.persistAppAuthSession(appSession)
            #if os(macOS)
            let reconciliation = ResolvedSessionReconciliationContext(
                cookieHeader: cookieHeader,
                sourceLabel: Self.appAuthSourceLabel,
                cacheObservation: context.cacheObservation,
                perform: context.perform,
                log: context.log)
            let reconciled = try await self.reconcileResolvedSession(value: value, context: reconciliation)
            return .succeeded(reconciled)
            #else
            return .succeeded(value)
            #endif
        } catch let error as CursorStatusProbeError {
            guard case .notLoggedIn = error else { throw error }
            context.log("Cursor.app local auth was rejected; falling back to browser cookies")
            let storedCookies = Self.removingAppSession(appSession, from: context.storedCookies)
            await CursorSessionStore.shared.setCookies(storedCookies)
            return .resumeFallback(storedCookies: storedCookies)
        } catch {
            throw CursorStatusProbeError.networkError(error.localizedDescription)
        }
    }

    private static func persistedAppSession(
        cachedEntry: CookieHeaderCache.Entry?,
        storedCookies: [HTTPCookie]) -> CursorAppAuthSession?
    {
        if let cachedEntry,
           cachedEntry.sourceLabel == Self.appAuthSourceLabel,
           let session = CursorAppAuthSession.from(cookieHeader: cachedEntry.cookieHeader)
        {
            return session
        }
        let storedHeader = storedCookies
            .filter(CursorAppAuthSession.isPersistedCookie)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return CursorAppAuthSession.from(cookieHeader: storedHeader)
    }

    private static func removingAppSession(
        _ appSession: CursorAppAuthSession,
        from cookies: [HTTPCookie]) -> [HTTPCookie]
    {
        cookies.filter { cookie in
            guard CursorAppAuthSession.isPersistedCookie(cookie) else { return true }
            let value = cookie.value.removingPercentEncoding ?? cookie.value
            return value.components(separatedBy: "::").last != appSession.accessToken
        }
    }

    private static func logIdentityMismatchIfNeeded(
        appIdentity: CursorSessionIdentity?,
        cachedEntry: CookieHeaderCache.Entry?,
        storedCookies: [HTTPCookie],
        log: (String) -> Void)
    {
        guard let appIdentity else { return }
        let browserIdentity: CursorSessionIdentity? = if let cachedEntry,
                                                         cachedEntry.sourceLabel != Self.appAuthSourceLabel
        {
            CursorSessionIdentity.from(cookieHeader: cachedEntry.cookieHeader)
        } else {
            CursorSessionIdentity.from(
                cookieHeader: storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
        guard let browserIdentity,
              appIdentity.differs(from: browserIdentity) == true
        else { return }

        let appLabel = appIdentity.displayLabel ?? "unknown account"
        let browserLabel = browserIdentity.displayLabel ?? "unknown account"
        let message = "Cursor.app account \(appLabel) differs from browser session \(browserLabel); "
            + "using Cursor.app account \(appLabel)"
        CodexBarLog.logger(LogCategories.cursor).warning(message)
        log(message)
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
