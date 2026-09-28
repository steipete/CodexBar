import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One validated row per provider; the cookie cache owns conditional writes and refresh transactions.
final class ProviderPluginPersistentCookies {
    private struct Payload: Codable {
        var records: [ProviderPluginCookieRecord]?
        var headersByHost: [String: String]?
    }

    private struct Issued: Sendable {
        let session: ProviderPluginCookieSession
        let expected: CookieHeaderCache.Entry?
        let file: [String: String]?
        let fromFile: Bool
    }

    private let provider: UsageProvider
    private let policy: ProviderPluginCookiePolicy
    private let file: ProviderPluginSessionFile?
    private let background: Bool
    private var readCache = false
    private var candidates: [ProviderPluginCookieSession]?
    private var issued: [String: Issued] = [:]
    private var pendingCache: CookieHeaderCache.Entry?
    private var expected: CookieHeaderCache.Entry?
    private var fileSnapshot: [String: String]?

    init(provider: UsageProvider, policy: ProviderPluginCookiePolicy, background: Bool, fileURL: URL? = nil) {
        self.provider = provider
        self.policy = policy
        self.background = background
        self.file = policy.sessionFile.map { ProviderPluginSessionFile(provider: provider, policy: $0, url: fileURL) }
    }

    func next(domain: String, cachedOnly: Bool, importer: ProviderPluginCookieBroker.JarImporter) throws
        -> ProviderPluginCookieSession?
    {
        guard self.policy.requestHosts.contains(domain) else {
            throw ProviderPluginError.secretAccess("cookie session destination is not declared")
        }
        if !self.readCache {
            self.readCache = true
            self.expected = CookieHeaderCache.load(provider: self.provider)
            self.pendingCache = self.expected
            self.fileSnapshot = self.file?.read()
            if self.background, !CookieHeaderCache.isRefreshReadSuppressed(provider: self.provider),
               let values = self.fileSnapshot, let header = self.file?.header(values)
            {
                return self.issue(
                    Payload(headersByHost: [domain: header]),
                    domain: domain,
                    source: values["sourceLabel"] ?? "Saved session",
                    cachedAt: 0,
                    fromFile: true)
            }
        }
        if let entry = self.pendingCache {
            self.pendingCache = nil
            if let payload = self.decode(entry.cookieHeader, domain: domain) {
                return self.issue(
                    payload,
                    domain: domain,
                    source: entry.sourceLabel,
                    cachedAt: entry.storedAt.timeIntervalSince1970)
            }
        }
        guard !cachedOnly else { return nil }
        if self.candidates == nil { self.candidates = try importer() }
        while self.candidates?.isEmpty == false {
            let candidate = self.candidates!.removeFirst()
            guard let selected = self.policy.selected(candidate.records ?? [], domain: domain) else { continue }
            return self.issue(Payload(records: selected), domain: domain, source: candidate.source)
        }
        return nil
    }

    func accept(domain: String, id: String) throws {
        guard let issued = self.issued[id], issued.session.origin == "https://\(domain)" else {
            throw ProviderPluginError.secretAccess("validated cookie session is unavailable")
        }
        let payload = Payload(records: issued.session.records, headersByHost: issued.session.headersByHost)
        let encoded = try Self.encode(payload)
        let header = try? ProviderPluginCookieJar.header(for: issued.session, url: URL(string: "https://\(domain)/")!)
        let file = self.file
        let storedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let entry = CookieHeaderCache.Entry(
            cookieHeader: encoded,
            storedAt: storedAt,
            sourceLabel: issued.session.source)
        let saved = CookieHeaderCache.storeIfCurrent(
            provider: self.provider,
            expected: issued.expected,
            cookieHeader: encoded,
            sourceLabel: issued.session.source,
            now: storedAt,
            onCommit: { file?.replace(expected: issued.file, header: header, source: issued.session.source) })
        if saved {
            self.expected = entry
            self.fileSnapshot = file?.values(header: header, source: issued.session.source)
            self.issued[id] = Issued(
                session: issued.session,
                expected: self.expected,
                file: self.fileSnapshot,
                fromFile: false)
        }
    }

    func reject(domain: String, id: String) {
        guard let issued = self.issued[id], issued.session.origin == "https://\(domain)" else { return }
        self.issued[id] = nil
        let file = self.file
        if issued.fromFile {
            if !CookieHeaderCache.isRefreshReadSuppressed(provider: self.provider) {
                file?.replace(expected: issued.file, header: nil, source: issued.session.source)
                self.fileSnapshot = file?.read()
            }
            return
        }
        if CookieHeaderCache.clearIfCurrent(provider: self.provider, expected: issued.expected, onClear: {
            file?.replace(expected: issued.file, header: nil, source: issued.session.source)
        }) {
            self.expected = nil
            self.fileSnapshot = self.file?.read()
        }
    }

    private func issue(
        _ payload: Payload, domain: String, source: String, cachedAt: TimeInterval? = nil, fromFile: Bool = false)
        -> ProviderPluginCookieSession
    {
        // Hash the canonical credential, never the per-fetch ID, so bearer caches survive refreshes.
        let canonical = (try? Self.encode(payload)) ?? ""
        let key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let session = ProviderPluginCookieSession(
            header: "",
            source: source,
            origin: "https://\(domain)",
            cachedAt: cachedAt,
            records: payload.records,
            headersByHost: payload.headersByHost,
            cacheKey: key,
            permitsEmptyHosts: self.policy.missingCookies == .omit ? self.policy.requestHosts : [])
        self.issued[session.id] = Issued(
            session: session,
            expected: self.expected,
            file: self.fileSnapshot,
            fromFile: fromFile)
        return session
    }

    private func decode(_ raw: String, domain: String) -> Payload? {
        if let data = raw.data(using: .utf8), var payload = try? JSONDecoder().decode(Payload.self, from: data) {
            if let records = payload.records {
                payload.records = self.policy.selected(records, domain: domain)
            }
            payload.headersByHost = payload.headersByHost?.filter { self.policy.requestHosts.contains($0.key) }
            return payload.records != nil || payload.headersByHost?.isEmpty == false ? payload : nil
        }
        // Native single-origin caches store the plain header; paired-host caches use headersByHost above.
        guard self.policy.requestHosts.count == 1,
              let header = CookieHeaderNormalizer.normalize(raw), !CookieHeaderNormalizer.pairs(from: header).isEmpty
        else { return nil }
        guard self.policy.requiredCookies.isSubset(of: Set(CookieHeaderNormalizer.pairs(from: header).map(\.name)))
        else { return nil }
        return Payload(headersByHost: [domain: header])
    }

    private static func encode(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try String(data: encoder.encode(payload), encoding: .utf8) else {
            throw ProviderPluginError.secretAccess("cookie cache encoding failed")
        }
        return encoded
    }
}
