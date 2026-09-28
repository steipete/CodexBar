import Foundation

#if os(macOS)
import SweetCookieKit
#endif

/// One origin-bound candidate. Its opaque ID prevents a late rejection from targeting its successor.
public struct ProviderPluginCookieSession: Codable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let source: String
    public let origin: String
    public let cachedAt: TimeInterval?
    public let records: [ProviderPluginCookieRecord]?
    let headersByHost: [String: String]?
    let cacheKey: String?
    let permitsEmptyHosts: Set<String>

    public init(
        header: String,
        source: String,
        origin: String,
        id: String = UUID().uuidString,
        cachedAt: TimeInterval? = nil,
        records: [ProviderPluginCookieRecord]? = nil,
        headersByHost: [String: String]? = nil,
        cacheKey: String? = nil,
        permitsEmptyHosts: Set<String> = [])
    {
        self.id = id
        self.header = header
        self.source = source
        self.origin = origin
        self.cachedAt = cachedAt
        self.records = records
        self.headersByHost = headersByHost
        self.cacheKey = cacheKey
        self.permitsEmptyHosts = permitsEmptyHosts
    }

    var redactionValues: [String] {
        let headers = [self.header] + Array(self.headersByHost?.values ?? [:].values)
        return headers + headers.flatMap { CookieHeaderNormalizer.pairs(from: $0).map(\.value) }
            + (self.records ?? []).map(\.value)
    }

    func json(opaque: Bool = false) throws -> String {
        var value: [String: Any] = ["id": self.id, "source": self.source, "origin": self.origin]
        if !opaque { value["header"] = self.header }
        if let cachedAt { value["cachedAt"] = cachedAt }
        if let cacheKey { value["cacheKey"] = cacheKey }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProviderPluginError.secretAccess("cookie session encoding failed")
        }
        return json
    }
}

final class ProviderPluginCookieBroker: @unchecked Sendable {
    typealias Importer = @Sendable (String) throws -> [(header: String, source: String)]
    typealias BatchImporter = @Sendable (String, Int) throws -> [(header: String, source: String)]?
    typealias JarImporter = @Sendable () throws -> [ProviderPluginCookieSession]

    private struct Issued {
        let session: ProviderPluginCookieSession
        let cacheEntry: CookieHeaderCache.Entry?
        let cacheScope: CookieHeaderCache.Scope?
    }

    private let provider: UsageProvider
    private let domains: Set<String>
    private let settings: ProviderSettingsSnapshot.CookieProviderSettings
    private let importer: BatchImporter
    private var importBatches: [String: Int] = [:]
    private var exhaustedImports = Set<String>()
    private let lock = NSLock()
    private var observed: [String: Issued] = [:]
    private var issuedSessions: [String: Issued] = [:]
    private var visited = Set<String>()
    private var imported: [String: [(header: String, source: String)]] = [:]
    private var seen: [String: Set<String>] = [:]
    private var manualDomain: String?
    private let jarImporter: JarImporter?
    private var jarCandidates: [ProviderPluginCookieSession]?
    private let persistent: ProviderPluginPersistentCookies?
    private let policy: ProviderPluginCookiePolicy?

    convenience init(
        provider: UsageProvider,
        domains: Set<String>,
        context: ProviderFetchContext,
        importer: BatchImporter? = nil,
        usesCookieJar: Bool = false,
        policy: ProviderPluginCookiePolicy? = nil,
        settingsOverride: ProviderSettingsSnapshot.CookieProviderSettings? = nil)
    {
        let interaction = ProviderInteractionContext.current
        let canImport = policy?.allowsImportAttempt(runtime: context.runtime, interaction: interaction)
            ?? (context.runtime == .app && interaction == .userInitiated)
        let jarImporter: JarImporter? = if usesCookieJar || policy != nil {
            {
                guard canImport else { return [] }
                return try Self.importCookieJars(
                    provider: provider, domains: domains, browserDetection: context.browserDetection)
            }
        } else {
            nil
        }
        self.init(
            provider: provider,
            domains: domains,
            settings: settingsOverride ?? context.settings.flatMap {
                ProviderDescriptorRegistry.descriptor(for: provider).settingsSection.cookieSettings(from: $0)
            } ?? .init(cookieSource: .auto, manualCookieHeader: nil),
            batches: importer ?? { domain, batch in
                guard batch == 0 else { return nil }
                return try Self.importCookieHeaders(
                    provider: provider, domain: domain, browserDetection: context.browserDetection)
            },
            jarImporter: jarImporter,
            policy: policy,
            background: ProviderInteractionContext.current != .userInitiated)
    }

    convenience init(
        provider: UsageProvider,
        domains: Set<String>,
        settings: ProviderSettingsSnapshot.CookieProviderSettings,
        importer: @escaping Importer)
    {
        self.init(provider: provider, domains: domains, settings: settings, batches: { domain, batch in
            try batch == 0 ? importer(domain) : nil
        })
    }

    init(
        provider: UsageProvider,
        domains: Set<String>,
        settings: ProviderSettingsSnapshot.CookieProviderSettings,
        batches: @escaping BatchImporter,
        jarImporter: JarImporter? = nil,
        policy: ProviderPluginCookiePolicy? = nil,
        background: Bool = false,
        sessionFileURL: URL? = nil)
    {
        self.provider = provider
        self.domains = domains
        self.settings = settings
        self.importer = batches
        #if os(macOS)
        self.jarImporter = jarImporter.map { BrowserCookieAccessGate.operationPreservingAccessContext($0) }
        #else
        self.jarImporter = jarImporter
        #endif
        self.policy = policy
        self.persistent = policy.flatMap {
            $0.cache == .validatedSingleEntry
                ? ProviderPluginPersistentCookies(
                    provider: provider,
                    policy: $0,
                    background: background,
                    fileURL: sessionFileURL)
                : nil
        }
    }

    var cookieSource: ProviderCookieSource {
        self.settings.cookieSource
    }

    func cookieHeader(domain: String) throws -> String {
        try self.lock.withLock {
            try self.validate(domain)
            guard self.jarImporter == nil else {
                throw ProviderPluginError.secretAccess("cookie jars do not expose headers")
            }
            if let issued = self.observed[domain] { return issued.session.header }
            guard let session = try self.advance(domain: domain) else {
                throw ProviderPluginError.secretAccess("no session cookies were found for this domain")
            }
            return session.header
        }
    }

    func nextSession(domain: String, cachedOnly: Bool = false) throws -> ProviderPluginCookieSession? {
        try self.lock.withLock {
            try self.validate(domain)
            return try self.advance(domain: domain, cachedOnly: cachedOnly)
        }
    }

    func acceptCookie(domain: String, id: String) throws {
        try self.lock.withLock {
            try self.validate(domain)
            guard let persistent else { throw ProviderPluginError.secretAccess("cookie persistence is not declared") }
            try persistent.accept(domain: domain, id: id)
        }
    }

    func rejectCookie(domain: String, id: String? = nil) {
        self.lock.withLock {
            if let persistent, let id {
                persistent.reject(domain: domain, id: id)
                return
            }
            guard self.domains.contains(domain),
                  let issued = id.flatMap({ self.issuedSessions[$0] }) ?? self.observed[domain],
                  id == nil || id == issued.session.id,
                  issued.session.origin == "https://\(domain)" else { return }
            if self.observed[domain]?.session.id == issued.session.id { self.observed[domain] = nil }
            self.issuedSessions[issued.session.id] = nil
            if let expected = issued.cacheEntry {
                CookieHeaderCache.clearIfCurrent(provider: self.provider, scope: issued.cacheScope, expected: expected)
            }
        }
    }

    private func validate(_ domain: String) throws {
        guard self.domains.contains(domain) else {
            throw ProviderPluginError.secretAccess("cookie domain is not declared")
        }
        guard self.settings.cookieSource != .off else {
            throw ProviderPluginError.secretAccess("browser cookies are disabled for this provider")
        }
    }

    private func advance(domain: String, cachedOnly: Bool = false) throws -> ProviderPluginCookieSession? {
        self.observed[domain] = nil
        if self.settings.cookieSource == .manual {
            // Legacy origin-less headers are pinned to the first selected domain for this fetch.
            let origin = self.settings.manualCookieOrigin ?? self.manualDomain.map { "https://\($0)" }
            guard origin == nil || origin == "https://\(domain)",
                  !self.visited.contains(domain),
                  let header = CookieHeaderNormalizer.normalize(self.settings.manualCookieHeader)
                  ?? (self.policy?.missingCookies == .omit ? "" : nil)
            else { return nil }
            self.manualDomain = domain
            self.visited.insert(domain)
            return self.issue(header: header, source: "manual", domain: domain, cacheEntry: nil)
        }
        if let jarImporter {
            if let persistent {
                return try persistent.next(domain: domain, cachedOnly: cachedOnly, importer: jarImporter)
            }
            guard !cachedOnly else { return nil }
            if self.jarCandidates == nil { self.jarCandidates = try jarImporter() }
            while self.jarCandidates?.isEmpty == false {
                let candidate = self.jarCandidates!.removeFirst()
                let records = self.policy.map { $0.selected(candidate.records ?? [], domain: domain) } ?? candidate
                    .records
                if self.policy != nil, records == nil { continue }
                let session = ProviderPluginCookieSession(
                    header: "", source: candidate.source, origin: "https://\(domain)", records: records)
                let issued = Issued(session: session, cacheEntry: nil, cacheScope: nil)
                self.observed[domain] = issued
                self.issuedSessions[session.id] = issued
                return session
            }
            return nil
        }
        if self.visited.insert(domain).inserted,
           let (cached, scope) = self.cachedEntry(domain: domain),
           let header = CookieHeaderNormalizer.normalize(cached.cookieHeader)
        {
            self.seen[domain, default: []].insert(header)
            return self.issue(
                header: header,
                source: cached.sourceLabel,
                domain: domain,
                cacheEntry: cached,
                cacheScope: scope,
                cachedAt: cached.storedAt.timeIntervalSince1970)
        }
        guard !cachedOnly else { return nil }
        while !self.exhaustedImports.contains(domain) {
            if self.imported[domain]?.isEmpty != false {
                let batch = self.importBatches[domain, default: 0]
                self.importBatches[domain] = batch + 1
                guard let candidates = try self.importer(domain, batch) else {
                    self.exhaustedImports.insert(domain)
                    break
                }
                self.imported[domain] = candidates
                if candidates.isEmpty { continue }
            }
            var candidates = self.imported[domain] ?? []
            let candidate = candidates.removeFirst()
            self.imported[domain] = candidates
            guard let header = CookieHeaderNormalizer.normalize(candidate.header),
                  self.seen[domain, default: []].insert(header).inserted else { continue }
            // Cache dates round to whole seconds. Keep the issued identity even if persistence fails.
            let entry = CookieHeaderCache.Entry(
                cookieHeader: header,
                storedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                sourceLabel: candidate.source)
            CookieHeaderCache.store(
                provider: self.provider,
                scope: self.scope(domain),
                cookieHeader: header,
                sourceLabel: entry.sourceLabel,
                now: entry.storedAt)
            return self.issue(
                header: header,
                source: candidate.source,
                domain: domain,
                cacheEntry: entry,
                cacheScope: self.scope(domain))
        }
        return nil
    }

    private func issue(
        header: String,
        source: String,
        domain: String,
        cacheEntry: CookieHeaderCache.Entry?,
        cacheScope: CookieHeaderCache.Scope? = nil,
        cachedAt: TimeInterval? = nil)
        -> ProviderPluginCookieSession
    {
        let session = ProviderPluginCookieSession(
            header: header,
            source: source,
            origin: "https://\(domain)",
            cachedAt: cachedAt,
            permitsEmptyHosts: self.policy?.missingCookies == .omit ? self.policy?.requestHosts ?? [] : [])
        let issued = Issued(session: session, cacheEntry: cacheEntry, cacheScope: cacheScope)
        self.observed[domain] = issued
        self.issuedSessions[session.id] = issued
        return session
    }

    private func cachedEntry(domain: String) -> (CookieHeaderCache.Entry, CookieHeaderCache.Scope?)? {
        let scope = self.scope(domain)
        if let entry = CookieHeaderCache.load(provider: self.provider, scope: scope) { return (entry, scope) }
        // Older regional fetchers recorded their origin in the source suffix of the unscoped cache.
        if scope != nil, let legacy = CookieHeaderCache.load(provider: self.provider),
           legacy.sourceLabel.hasSuffix(" / \(domain)")
        {
            return (legacy, nil)
        }
        return nil
    }

    private func scope(_ domain: String) -> CookieHeaderCache.Scope? {
        self.domains.count == 1 ? nil : .providerVariant(domain)
    }

    static func importCookieHeaders(
        provider: UsageProvider? = nil, domain: String, browserDetection: BrowserDetection) throws
        -> [(header: String, source: String)]
    {
        #if os(macOS)
        let query = Self.cookieQuery(domain: domain)
        let client = BrowserCookieClient()
        let order = provider.map { ProviderDefaults.metadata[$0]?.browserCookieOrder ?? Browser.defaultImportOrder }
            ?? [Browser.chrome]
        var sessions: [(header: String, source: String)] = []
        for browser in order.cookieImportCandidates(using: browserDetection) {
            do {
                for source in try client.codexBarRecords(matching: query, in: browser) {
                    let records = source.records.filter { Self.matches(cookieDomain: $0.domain, domain: domain) }
                    let cookies = Self.cookiesForRequest(
                        BrowserCookieClient.makeHTTPCookies(records, origin: query.origin), domain: domain)
                    let rawHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    if let header = CookieHeaderNormalizer.normalize(rawHeader) {
                        sessions.append((header, source.label))
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        return sessions
        #else
        return []
        #endif
    }

    static func importCookieJars(
        provider: UsageProvider, domains: Set<String>, browserDetection: BrowserDetection) throws
        -> [ProviderPluginCookieSession]
    {
        #if os(macOS)
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: domains.sorted(), domainMatch: .exact)
        let order = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? [Browser.chrome]
        return try BrowserCookieImportSupport.collectSessions(
            from: order.cookieImportCandidates(using: browserDetection),
            missingError: nil,
            logger: { _ in },
            load: { browser in
                let sources = try client.codexBarRecords(matching: query, in: browser)
                return BrowserCookieProfiles.merge(sources).map { profile in
                    ProviderPluginCookieSession(
                        header: "", source: profile.label, origin: "", records: profile.records
                            .filter { domains.contains(Self.normalizedDomain($0.domain)) }
                            .map(ProviderPluginCookieRecord.init))
                }
            })
        #else
        return []
        #endif
    }

    #if os(macOS)
    static func cookiesForRequest(_ cookies: [HTTPCookie], domain: String) -> [HTTPCookie] {
        var chosen: [String: HTTPCookie] = [:]
        var order: [String] = []
        for cookie in cookies where Self.matches(cookieDomain: cookie.domain, domain: domain) {
            if let existing = chosen[cookie.name] {
                // A host-specific session must not be shadowed by its parent-domain cookie.
                if Self.normalizedDomain(cookie.domain) == domain,
                   Self.normalizedDomain(existing.domain) != domain
                {
                    chosen[cookie.name] = cookie
                }
            } else {
                chosen[cookie.name] = cookie
                order.append(cookie.name)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    static func cookieQuery(domain: String) -> BrowserCookieQuery {
        let alternate = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : "www.\(domain)"
        return BrowserCookieQuery(domains: [domain, alternate], domainMatch: .exact)
    }
    #endif

    private static func normalizedDomain(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func matches(cookieDomain: String, domain: String) -> Bool {
        let cookieDomain = Self.normalizedDomain(cookieDomain)
        return cookieDomain == domain || cookieDomain == "www.\(domain)" || domain == "www.\(cookieDomain)"
    }
}

public enum UserProviderPluginCookieBroker {
    public static func resolver(
        browserDetection: BrowserDetection) -> ProviderPluginRuntime.InstanceCookieResolver
    {
        { _, domain in
            guard let session = try ProviderPluginCookieBroker.importCookieHeaders(
                domain: domain, browserDetection: browserDetection).first
            else {
                throw ProviderPluginError.secretAccess("no browser session cookies were found")
            }
            return session.header
        }
    }
}

extension ProviderPluginCookieSession {
    /// Existing injected header resolvers represent one candidate per domain, not a profile iterator.
    static func legacyResolver(
        provider: ProviderInstanceID,
        source: ProviderCookieSource,
        resolver: ProviderPluginRuntime.CookieResolver?,
        instanceResolver: ProviderPluginRuntime.InstanceCookieResolver?) -> ProviderPluginRuntime.CookieSessionResolver?
    {
        guard (provider.firstPartyProvider != nil && resolver != nil) || instanceResolver != nil else { return nil }
        let state = LegacySessionDomains()
        return { domain, cachedOnly in
            guard !cachedOnly else { return nil }
            guard state.take(domain, manual: source == .manual) else { return nil }
            let header: String
            if let firstParty = provider.firstPartyProvider, let resolver {
                header = try await resolver(firstParty, domain)
            } else if let instanceResolver {
                header = try await instanceResolver(provider, domain)
            } else {
                return nil
            }
            return Self(header: header, source: source == .manual ? "manual" : "browser", origin: "https://\(domain)")
        }
    }
}

private final class LegacySessionDomains: @unchecked Sendable {
    private let lock = NSLock()
    private var domains = Set<String>()

    func take(_ domain: String, manual: Bool) -> Bool {
        self.lock.withLock {
            guard !manual || self.domains.isEmpty else { return false }
            return self.domains.insert(domain).inserted
        }
    }
}
