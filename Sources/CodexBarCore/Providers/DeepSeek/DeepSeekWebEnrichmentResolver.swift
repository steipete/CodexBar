import Foundation

enum DeepSeekWebEnrichmentResolver {
    struct Candidate {
        let session: DeepSeekPlatformSession
        let sourceLabel: String
        let shouldCache: Bool
        let isCached: Bool
    }

    static func candidates(context: ProviderFetchContext) -> [Candidate] {
        let cookieSource = context.settings?.deepseek?.cookieSource ?? .auto
        if cookieSource == .off { return [] }

        if cookieSource == .manual {
            return self.deduplicated(self.manualCandidates(context: context))
        }

        var candidates = self.autoExplicitCandidates(context: context)
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .deepseek),
           let session = DeepSeekCookieHeader.session(from: cached.cookieHeader)
        {
            let sanitized = DeepSeekSessionAuthorization.sanitized(session)
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
        let cookieSource = context.settings?.deepseek?.cookieSource ?? .auto
        if cookieSource == .off { return false }
        if cookieSource == .manual {
            return !self.manualCandidates(context: context).isEmpty
        }
        if !self.autoExplicitCandidates(context: context).isEmpty {
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

    static func hasConfiguredWebSession(
        settings: ProviderSettingsSnapshot?,
        environment: [String: String]) -> Bool
    {
        let cookieSource = settings?.deepseek?.cookieSource ?? .auto
        if cookieSource == .off { return false }
        if cookieSource == .manual {
            return self.manualSession(from: settings?.deepseek?.manualCookieHeader) != nil
        }
        if self.manualSession(from: settings?.deepseek?.manualCookieHeader) != nil {
            return true
        }
        if ProviderTokenResolver.deepseekCookie(environment: environment) != nil {
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
        CookieHeaderCache.storeCredentialPayload(
            provider: .deepseek,
            payload: payload,
            sourceLabel: candidate.sourceLabel)
    }

    #if os(macOS)
    static func allowsBrowserCookieImport(context: ProviderFetchContext) -> Bool {
        context.runtime == .app && ProviderInteractionContext.current == .userInitiated
    }
    #endif

    private static func manualCandidates(context: ProviderFetchContext) -> [Candidate] {
        guard let session = self.manualSession(from: context.settings?.deepseek?.manualCookieHeader) else {
            return []
        }
        return [Candidate(
            session: session,
            sourceLabel: "settings",
            shouldCache: false,
            isCached: false)]
    }

    private static func autoExplicitCandidates(context: ProviderFetchContext) -> [Candidate] {
        var candidates: [Candidate] = []
        if let session = self.manualSession(from: context.settings?.deepseek?.manualCookieHeader) {
            candidates.append(Candidate(
                session: session,
                sourceLabel: "settings",
                shouldCache: false,
                isCached: false))
        }
        if let raw = ProviderTokenResolver.deepseekCookie(environment: context.env),
           let session = DeepSeekCookieHeader.session(from: raw)
        {
            let sanitized = DeepSeekSessionAuthorization.sanitized(session)
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

    private static func manualSession(from raw: String?) -> DeepSeekPlatformSession? {
        guard let header = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty,
              let session = DeepSeekCookieHeader.session(from: header)
        else {
            return nil
        }
        let sanitized = DeepSeekSessionAuthorization.sanitized(session)
        return sanitized.isEmpty ? nil : sanitized
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
