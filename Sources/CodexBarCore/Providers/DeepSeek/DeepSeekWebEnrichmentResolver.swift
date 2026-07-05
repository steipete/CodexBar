import Foundation

enum DeepSeekWebEnrichmentResolver {
    struct Candidate {
        let session: DeepSeekPlatformSession
        let sourceLabel: String
        let shouldCache: Bool
        let isCached: Bool
    }

    static func candidates(context: ProviderFetchContext) -> [Candidate] {
        // When the user disables usage summaries, no session source is eligible —
        // including environment cookies, cache, and browser imports.
        if context.settings?.deepseek?.cookieSource == .off { return [] }
        var candidates = self.explicitCandidates(context: context)
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .deepseek),
           let session = DeepSeekCookieHeader.session(from: cached.cookieHeader)
        {
            let sanitized = DeepSeekLocalStorageImporter.sanitized(session)
            if sanitized.isEmpty {
                CookieHeaderCache.clear(provider: .deepseek)
            } else {
                candidates.append(Candidate(
                    session: sanitized,
                    sourceLabel: cached.sourceLabel,
                    shouldCache: false,
                    isCached: true))
            }
        }
        if self.allowsBrowserCookieImport(context: context) {
            let sessions = (try? DeepSeekCookieImporter.importSessions(
                browserDetection: context.browserDetection)) ?? []
            for session in sessions {
                candidates.append(Candidate(
                    session: session.session,
                    sourceLabel: session.sourceLabel,
                    shouldCache: true,
                    isCached: false))
            }
        }
        #endif
        return self.deduplicated(candidates)
    }

    /// Lightweight availability probe: checks explicit (settings/env) sessions and the
    /// cached cookie without triggering a browser import or Keychain-prompting read.
    static func hasExplicitOrCachedSession(context: ProviderFetchContext) -> Bool {
        if !self.explicitCandidates(context: context).isEmpty {
            return true
        }
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .deepseek),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        #endif
        return false
    }

    static func cacheValidated(_ candidate: Candidate) {
        guard candidate.shouldCache else { return }
        let payload = candidate.session.storagePayload
        guard !payload.isEmpty else { return }
        CookieHeaderCache.store(
            provider: .deepseek,
            cookieHeader: payload,
            sourceLabel: candidate.sourceLabel)
    }

    #if os(macOS)
    static func allowsBrowserCookieImport(context: ProviderFetchContext) -> Bool {
        context.runtime == .app && ProviderInteractionContext.current == .userInitiated
    }
    #endif

    private static func explicitCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let settings = context.settings?.deepseek,
           settings.cookieSource != .off,
           let header = settings.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty,
           let session = DeepSeekCookieHeader.session(from: header)
        {
            let sanitized = DeepSeekLocalStorageImporter.sanitized(session)
            if !sanitized.isEmpty {
                candidates.append(Candidate(
                    session: sanitized,
                    sourceLabel: "settings",
                    shouldCache: false,
                    isCached: false))
            }
        }
        if let raw = ProviderTokenResolver.deepseekCookie(environment: context.env),
           let session = DeepSeekCookieHeader.session(from: raw)
        {
            let sanitized = DeepSeekLocalStorageImporter.sanitized(session)
            if !sanitized.isEmpty {
                candidates.append(Candidate(
                    session: sanitized,
                    sourceLabel: "environment",
                    shouldCache: false,
                    isCached: false))
            }
        }
        return candidates
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = [
                candidate.session.cookieHeader ?? "",
                candidate.session.authorizationHeader ?? "",
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }
}
