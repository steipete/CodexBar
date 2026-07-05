import Foundation

enum MiniMaxWebEnrichmentResolver {
    struct Candidate {
        let override: MiniMaxCookieOverride
        let sourceLabel: String
        let shouldCache: Bool
        let isCached: Bool
    }

    /// Full candidate chain for cookie-first web refreshes (desktop, cache, browser, explicit).
    static func candidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates = self.explicitCandidates(context: context)

        #if os(macOS)
        candidates.append(contentsOf: self.desktopAgentCandidates(context: context))
        candidates.append(contentsOf: self.cachedAndBrowserCandidates(context: context))
        #endif
        return self.deduplicated(candidates)
    }

    /// API-token enrichment: explicit cookies, desktop Agent session, validated cache, and user-initiated
    /// browser import only.
    #if os(macOS)
    static func apiEnrichmentCandidates(
        context: ProviderFetchContext,
        desktopSession: MiniMaxCookieImporter.SessionInfo? = nil) -> [Candidate]
    {
        var candidates = self.explicitCandidates(context: context)
        candidates.append(contentsOf: self.desktopAgentCandidates(
            context: context,
            session: desktopSession))
        candidates.append(contentsOf: self.cachedAndBrowserCandidates(context: context))
        return self.deduplicated(candidates)
    }
    #else
    static func apiEnrichmentCandidates(context: ProviderFetchContext) -> [Candidate] {
        self.deduplicated(self.explicitCandidates(context: context))
    }
    #endif

    /// Cookies from explicit user configuration only.
    static func explicitCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let settings = context.settings?.minimax,
           settings.cookieSource == .manual,
           let header = settings.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty,
           let override = MiniMaxCookieHeader.override(from: header)
        {
            candidates.append(Candidate(
                override: override, sourceLabel: "settings", shouldCache: false, isCached: false))
        }
        if let raw = ProviderTokenResolver.minimaxCookie(environment: context.env),
           let override = MiniMaxCookieHeader.override(from: raw)
        {
            candidates.append(Candidate(
                override: override, sourceLabel: "environment", shouldCache: false, isCached: false))
        }
        return candidates
    }

    static func cacheValidated(_ candidate: Candidate) {
        guard candidate.shouldCache else { return }
        CookieHeaderCache.store(
            provider: .minimax,
            cookieHeader: candidate.override.cookieHeader,
            sourceLabel: candidate.sourceLabel)
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.override.cookieHeader).inserted }
    }

    #if os(macOS)
    static func allowsBrowserCookieImport(context: ProviderFetchContext) -> Bool {
        context.runtime == .app && ProviderInteractionContext.current == .userInitiated
    }

    static func desktopAgentCandidates(
        context: ProviderFetchContext,
        session: MiniMaxCookieImporter.SessionInfo? = nil) -> [Candidate]
    {
        guard let session = session ?? MiniMaxDesktopCookieImporter.importSession(),
              let override = MiniMaxCookieHeader.override(from: session.cookieHeader)
        else {
            return []
        }
        return [Candidate(
            override: self.enrichWithBrowserTokens(
                override,
                sourceLabel: session.sourceLabel,
                browserDetection: context.browserDetection),
            sourceLabel: session.sourceLabel,
            shouldCache: true,
            isCached: false)]
    }

    private static func cachedAndBrowserCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let cached = CookieHeaderCache.load(provider: .minimax),
           let override = MiniMaxCookieHeader.override(from: cached.cookieHeader)
        {
            candidates.append(Candidate(
                override: self.enrichWithBrowserTokens(
                    override,
                    sourceLabel: cached.sourceLabel,
                    browserDetection: context.browserDetection),
                sourceLabel: cached.sourceLabel,
                shouldCache: false,
                isCached: true))
        }
        if self.allowsBrowserCookieImport(context: context) {
            let sessions = (try? MiniMaxCookieImporter.importSessions(
                browserDetection: context.browserDetection)) ?? []
            for session in sessions {
                guard let override = MiniMaxCookieHeader.override(from: session.cookieHeader) else { continue }
                candidates.append(Candidate(
                    override: self.enrichWithBrowserTokens(
                        override,
                        sourceLabel: session.sourceLabel,
                        browserDetection: context.browserDetection),
                    sourceLabel: session.sourceLabel,
                    shouldCache: true,
                    isCached: false))
            }
        }
        return candidates
    }

    private static func enrichWithBrowserTokens(
        _ override: MiniMaxCookieOverride,
        sourceLabel: String,
        browserDetection: BrowserDetection) -> MiniMaxCookieOverride
    {
        if override.authorizationToken != nil, override.groupID != nil { return override }
        let accessTokens = MiniMaxLocalStorageImporter.importAccessTokens(browserDetection: browserDetection)
        let groupIDs = MiniMaxLocalStorageImporter.importGroupIDs(browserDetection: browserDetection)
        let normalizedLabel = self.normalizeStorageLabel(sourceLabel)
        let matchingToken = accessTokens.first {
            self.normalizeStorageLabel($0.sourceLabel) == normalizedLabel
        }
        let matchingGroupID = groupIDs.first {
            self.normalizeStorageLabel($0.key) == normalizedLabel
        }?.value
        return MiniMaxCookieOverride(
            cookieHeader: override.cookieHeader,
            authorizationToken: override.authorizationToken
                ?? matchingToken?.accessToken
                ?? self.cookieValue(named: "HERTZ-SESSION", in: override.cookieHeader),
            groupID: override.groupID
                ?? matchingToken?.groupID
                ?? matchingGroupID
                ?? self.cookieValue(named: "minimax_group_id_v2", in: override.cookieHeader))
    }

    private static func normalizeStorageLabel(_ label: String) -> String {
        for suffix in [" (Session Storage)", " (IndexedDB)"] where label.hasSuffix(suffix) {
            return String(label.dropLast(suffix.count))
        }
        return label
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        header.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.lowercased().hasPrefix("\(name.lowercased())=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }
    #endif
}
