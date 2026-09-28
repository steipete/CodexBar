import Foundation
#if os(macOS)
import SweetCookieKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Host-owned browser records. The JavaScript bridge exposes only a session identifier.
public struct ProviderPluginCookieRecord: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let hostOnly: Bool
    public let path: String
    public let secure: Bool
    public let expires: Date?

    #if os(macOS)
    init(record: BrowserCookieRecord) {
        self.name = record.name
        self.value = record.value
        self.domain = record.domain.lowercased()
        self.hostOnly = record.scope == .hostOnly
        self.path = record.path.isEmpty ? "/" : record.path
        self.secure = record.isSecure
        self.expires = record.expires
    }
    #endif

    public init(cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.hostOnly = !cookie.domain.hasPrefix(".")
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.secure = cookie.isSecure
        self.expires = cookie.expiresDate
    }

    private init(name: String, value: String, domain: String, expires: Date?) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = true
        self.path = "/"
        self.secure = true
        self.expires = expires
    }

    func bound(to domain: String) -> Self {
        Self(name: self.name, value: self.value, domain: domain, expires: self.expires)
    }

    func matches(_ url: URL, now: Date) -> Bool {
        guard let host = url.host?.lowercased(), self.expires.map({ $0 > now }) ?? true,
              !self.secure || url.scheme?.lowercased() == "https",
              host == self.domain || (!self.hostOnly && host.hasSuffix("." + self.domain))
        else { return false }
        let encodedPath = url.path(percentEncoded: true)
        let requestPath = Array((encodedPath.isEmpty ? "/" : encodedPath).utf8)
        let cookiePath = Array(self.path.utf8)
        guard requestPath.starts(with: cookiePath) else { return false }
        return requestPath.count == cookiePath.count || cookiePath.last == 47 || requestPath[cookiePath.count] == 47
    }

    static func header(_ records: [Self], for url: URL, now: Date = Date()) -> String? {
        let matching = records.filter { $0.matches(url, now: now) }.sorted {
            if $0.path.utf8.count != $1.path.utf8.count { return $0.path.utf8.count > $1.path.utf8.count }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.domain < $1.domain
        }
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// A new registry for every fetch prevents scripts from reusing or guessing another refresh's sessions.
final class ProviderPluginCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: ProviderPluginCookieSession] = [:]

    func register(_ session: ProviderPluginCookieSession) {
        self.lock.withLock { self.sessions[session.id] = session }
    }

    func contains(id: String, domain: String) -> Bool {
        self.lock.withLock { self.sessions[id]?.origin == "https://\(domain)" }
    }

    func reject(id: String) {
        _ = self.lock.withLock { self.sessions.removeValue(forKey: id) }
    }

    static func authenticate(
        _ request: inout URLRequest,
        sessionID: Any?,
        required: Bool,
        jar: ProviderPluginCookieJar?) throws
    {
        guard required || sessionID != nil else { return }
        guard required, let id = sessionID as? String, let jar, let url = request.url,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Host") == nil
        else {
            throw ProviderPluginError
                .secretAccess("request requires an opaque cookie session without header overrides")
        }
        try request.setValue(jar.header(id: id, url: url), forHTTPHeaderField: "Cookie")
    }

    func header(id: String, url: URL, now: Date = Date()) throws -> String {
        guard let session = self.lock.withLock({ self.sessions[id] }),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil
        else { throw ProviderPluginError.secretAccess("cookie session is unavailable") }
        return try Self.header(for: session, url: url, now: now)
    }

    static func header(for session: ProviderPluginCookieSession, url: URL, now: Date = Date()) throws -> String {
        let header: String? = if let records = session.records {
            ProviderPluginCookieRecord.header(records, for: url, now: now)
        } else if let headers = session.headersByHost {
            headers[url.host?.lowercased() ?? ""]
        } else {
            session.origin == "https://\(url.host?.lowercased() ?? "")" ? session.header : nil
        }
        if header == nil, session.permitsEmptyHosts.contains(url.host?.lowercased() ?? "") { return "" }
        guard let header, !header.isEmpty || session.permitsEmptyHosts.contains(url.host?.lowercased() ?? "") else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: "No session cookies match this request URL.")
        }
        return header
    }
}

/// Imported cookies never enter URLSession storage; redirects reselect them using the same URL matcher.
struct ProviderPluginCookieTransport: ProviderHTTPTransport {
    let base: any ProviderHTTPTransport
    let jar: ProviderPluginCookieJar
    let id: String
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        var request = request
        try request.setValue(self.jar.header(id: self.id, url: url), forHTTPHeaderField: "Cookie")
        // Synthetic/injected transports remain under the caller's control; the production default is isolated here.
        if let client = self.base as? ProviderHTTPClient, client === ProviderHTTPClient.shared {
            return try await Self.session.data(
                for: request,
                delegate: CookieRedirectDelegate(jar: self.jar, id: self.id))
        }
        return try await self.base.data(for: request)
    }

    final class CookieRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let jar: ProviderPluginCookieJar
        let id: String

        init(jar: ProviderPluginCookieJar, id: String) {
            self.jar = jar
            self.id = id
        }

        func redirectedRequest(originalURL: URL?, request: URLRequest) -> URLRequest? {
            guard var request = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
                originalURL: originalURL, redirectRequest: request),
                let url = request.url, let header = try? self.jar.header(id: self.id, url: url)
            else { return nil }
            request.setValue(header, forHTTPHeaderField: "Cookie")
            return request
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(self.redirectedRequest(originalURL: task.originalRequest?.url, request: request))
        }
    }
}
