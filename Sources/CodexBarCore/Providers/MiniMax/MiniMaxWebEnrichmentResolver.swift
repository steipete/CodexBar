import Foundation

enum MiniMaxWebEnrichmentResolver {
    struct Candidate {
        let override: MiniMaxCookieOverride
        let sourceLabel: String
        let shouldCache: Bool
    }

    static func candidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        candidates.append(contentsOf: self.explicitCandidates(context: context))

        #if os(macOS)
        if let session = MiniMaxDesktopCookieImporter.importSession(),
           let override = MiniMaxCookieHeader.override(from: session.cookieHeader)
        {
            candidates.append(Candidate(
                override: self.enrichWithBrowserTokens(
                    override,
                    sourceLabel: session.sourceLabel,
                    browserDetection: context.browserDetection),
                sourceLabel: session.sourceLabel,
                shouldCache: true))
        }
        if let cached = CookieHeaderCache.load(provider: .minimax),
           let override = MiniMaxCookieHeader.override(from: cached.cookieHeader)
        {
            candidates.append(Candidate(
                override: self.enrichWithBrowserTokens(
                    override,
                    sourceLabel: cached.sourceLabel,
                    browserDetection: context.browserDetection),
                sourceLabel: cached.sourceLabel,
                shouldCache: false))
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
                    shouldCache: true))
            }
        }
        #endif
        return self.deduplicated(candidates)
    }

    /// Cookies from explicit user configuration only. API-token enrichment must not attach
    /// cached or imported browser/desktop sessions that may belong to a different MiniMax account.
    static func explicitCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let settings = context.settings?.minimax,
           let header = settings.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty,
           let override = MiniMaxCookieHeader.override(from: header)
        {
            candidates.append(Candidate(override: override, sourceLabel: "settings", shouldCache: false))
        }
        if let raw = ProviderTokenResolver.minimaxCookie(environment: context.env),
           let override = MiniMaxCookieHeader.override(from: raw)
        {
            candidates.append(Candidate(override: override, sourceLabel: "environment", shouldCache: false))
        }
        return self.deduplicated(candidates)
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
        context.runtime == .app &&
            (ProviderInteractionContext.current == .userInitiated || context.includeOptionalUsage)
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
