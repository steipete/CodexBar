import Foundation

/// Resolves the Nous Portal access token CodexBar uses for read-only billing lookups.
///
/// Nous Portal issues short-lived OAuth access tokens through the Hermes Agent device-code login. Refresh tokens
/// are single-use and the portal revokes the whole session when it detects reuse, so CodexBar never refreshes:
/// it only reads the access token Hermes already minted (`~/.hermes/auth.json`) or an explicit environment
/// override, and reports a clear "run `hermes`" message once that token expires.
public enum NousSettingsReader: Sendable {
    public static let accessTokenEnvironmentKey = "NOUS_PORTAL_ACCESS_TOKEN"
    public static let portalBaseURLEnvironmentKeys = ["NOUS_PORTAL_BASE_URL", "HERMES_PORTAL_BASE_URL"]
    public static let hermesHomeEnvironmentKey = "HERMES_HOME"
    public static let defaultPortalBaseURL = URL(string: "https://portal.nousresearch.com")!
    /// Hosts a Hermes auth file may point the bearer token at. Anything else falls back to the default portal so a
    /// tampered or stale `portal_base_url` can never redirect the credential to a third party.
    public static let trustedPortalHostSuffix = "nousresearch.com"
    /// Tokens closer to expiry than this are treated as expired so a fetch never races the portal clock.
    public static let expirySkew: TimeInterval = 60

    public enum CredentialSource: Sendable, Equatable {
        case environment
        case authFile(String)

        public var label: String {
            switch self {
            case .environment: "env"
            case .authFile: "hermes"
            }
        }
    }

    public struct Credential: Sendable, Equatable {
        public let token: String
        public let portalBaseURL: URL
        public let expiresAt: Date?
        public let source: CredentialSource
        /// Stored `portal_base_url` that failed the trusted-host policy, kept only for diagnostics.
        public let rejectedPortalHost: String?

        public init(
            token: String,
            portalBaseURL: URL,
            expiresAt: Date?,
            source: CredentialSource,
            rejectedPortalHost: String? = nil)
        {
            self.token = token
            self.portalBaseURL = portalBaseURL
            self.expiresAt = expiresAt
            self.source = source
            self.rejectedPortalHost = rejectedPortalHost
        }

        public func isExpired(now: Date = Date(), skew: TimeInterval = NousSettingsReader.expirySkew) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= skew
        }
    }

    /// Returns a usable (non-expired) credential, or nil when none is configured.
    public static func credential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> Credential?
    {
        try? self.resolveCredential(environment: environment, now: now)
    }

    /// Resolves the credential, throwing a typed error that explains what is missing or expired.
    public static func resolveCredential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) throws -> Credential
    {
        if let token = self.cleaned(environment[self.accessTokenEnvironmentKey]) {
            let credential = Credential(
                token: token,
                portalBaseURL: self.portalBaseURL(environment: environment, stored: nil).url,
                expiresAt: self.jwtExpiry(token),
                source: .environment)
            if credential.isExpired(now: now) {
                throw NousUsageError.environmentTokenExpired
            }
            return credential
        }

        var expired: Credential?
        var sawFile = false
        for url in self.authFileCandidates(environment: environment) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            sawFile = true
            guard let data = try? Data(contentsOf: url),
                  let stored = self.parseAuthFile(data: data)
            else { continue }
            let resolvedPortal = self.portalBaseURL(environment: environment, stored: stored.portalBaseURL)
            let credential = Credential(
                token: stored.token,
                portalBaseURL: resolvedPortal.url,
                expiresAt: stored.expiresAt ?? self.jwtExpiry(stored.token),
                source: .authFile(url.path),
                rejectedPortalHost: resolvedPortal.rejectedStoredHost)
            if credential.isExpired(now: now) {
                expired = expired ?? credential
                continue
            }
            return credential
        }

        if let expired, case let .authFile(path) = expired.source {
            throw NousUsageError.sessionExpired(path)
        }
        throw sawFile
            ? NousUsageError.authFileInvalid(self.authFileCandidates(environment: environment).first?.path ?? "")
            : NousUsageError.missingCredentials
    }

    public static func unavailableMessage(environment: [String: String]) -> String? {
        do {
            _ = try self.resolveCredential(environment: environment)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public struct PortalResolution: Sendable, Equatable {
        public let url: URL
        public let origin: PortalOrigin
        /// Host from a stored `portal_base_url` that was refused by the trusted-host policy.
        public let rejectedStoredHost: String?
    }

    public enum PortalOrigin: String, Sendable {
        case environmentOverride
        case storedTrusted
        case `default`
    }

    /// Resolves the portal origin the bearer token will be sent to.
    ///
    /// Precedence: explicit environment override (HTTPS, operator-controlled) → stored auth-file value when its host
    /// is `nousresearch.com` or a subdomain → the default portal. A stored host outside that policy is never used.
    public static func portalBaseURL(environment: [String: String], stored: String?) -> PortalResolution {
        for key in self.portalBaseURLEnvironmentKeys {
            if let raw = self.cleaned(environment[key]), let url = self.normalizedHTTPSURL(raw) {
                return PortalResolution(url: url, origin: .environmentOverride, rejectedStoredHost: nil)
            }
        }
        if let stored, let url = self.normalizedHTTPSURL(stored) {
            if self.isTrustedPortalHost(url.host) {
                return PortalResolution(url: url, origin: .storedTrusted, rejectedStoredHost: nil)
            }
            return PortalResolution(url: self.defaultPortalBaseURL, origin: .default, rejectedStoredHost: url.host)
        }
        return PortalResolution(url: self.defaultPortalBaseURL, origin: .default, rejectedStoredHost: nil)
    }

    public static func isTrustedPortalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host == self.trustedPortalHostSuffix || host.hasSuffix("." + self.trustedPortalHostSuffix)
    }

    // MARK: - Hermes auth store

    struct StoredCredential: Equatable {
        let token: String
        let portalBaseURL: String?
        let expiresAt: Date?
    }

    /// Hermes stores per-profile credentials in `auth.json` and a cross-profile copy in `shared/nous_auth.json`.
    ///
    /// An explicit `HERMES_HOME` is the exclusive credential root: when it is set, the default `~/.hermes` root is
    /// never consulted, so a missing, invalid, or expired custom profile can never fall through to another
    /// profile's token.
    static func authFileCandidates(environment: [String: String]) -> [URL] {
        let root: URL = if let override = self.cleaned(environment[self.hermesHomeEnvironmentKey]) {
            URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            self.defaultHermesHome(environment: environment)
        }
        return ["auth.json", "shared/nous_auth.json"].map { root.appendingPathComponent($0) }
    }

    static func defaultHermesHome(environment: [String: String]) -> URL {
        let home: URL = if let raw = self.cleaned(environment["HOME"]) {
            URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".hermes", isDirectory: true)
    }

    /// Accepts the three shapes Hermes writes: `providers.nous`, `credential_pool.nous[]`, or a bare state object.
    static func parseAuthFile(data: Data) -> StoredCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let providers = root["providers"] as? [String: Any],
           let nous = providers["nous"] as? [String: Any],
           let stored = self.storedCredential(from: nous)
        {
            return stored
        }
        if let pool = root["credential_pool"] as? [String: Any],
           let entries = pool["nous"] as? [[String: Any]]
        {
            for entry in entries {
                if let stored = self.storedCredential(from: entry) {
                    return stored
                }
            }
        }
        return self.storedCredential(from: root)
    }

    private static func storedCredential(from state: [String: Any]) -> StoredCredential? {
        guard let token = self.cleaned(state["access_token"] as? String) else { return nil }
        return StoredCredential(
            token: token,
            portalBaseURL: self.cleaned(state["portal_base_url"] as? String),
            expiresAt: (state["expires_at"] as? String).flatMap(Self.parseISODate))
    }

    // MARK: - Helpers

    static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Best-effort `exp` claim from a JWT so environment overrides also get expiry checks.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Accepts HTTPS origins only. Plain HTTP is refused for every host, loopback included, so the bearer token
    /// can never travel in cleartext regardless of where the override came from.
    static func normalizedHTTPSURL(_ raw: String) -> URL? {
        var value = raw
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
