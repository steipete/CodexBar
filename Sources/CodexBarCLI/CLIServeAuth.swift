import Crypto
import Foundation

/// Static bearer-token gate for the `/dashboard/v1/*` serve routes.
///
/// Comparison is constant-time: both the configured token and each presented
/// credential are reduced to SHA-256 digests, and the fixed-length digests are
/// compared without short-circuiting, so timing never leaks a matching prefix.
/// With no configured token the gate fails closed and authorizes nothing.
struct CLIServeDashboardAuth: Sendable {
    private let expectedTokenDigest: [UInt8]?

    init(bearer: String?) {
        self.expectedTokenDigest = bearer.map { Array(SHA256.hash(data: Data($0.utf8))) }
    }

    var isConfigured: Bool {
        self.expectedTokenDigest != nil
    }

    /// Authorizes a request against the configured token. The credential is read
    /// only from the `Authorization: Bearer <token>` header; query-string tokens
    /// are never accepted.
    func authorize(_ request: CLILocalHTTPRequest) -> Bool {
        guard let expectedTokenDigest else { return false }
        guard let token = Self.bearerToken(from: request.authorization) else { return false }
        let digest = Array(SHA256.hash(data: Data(token.utf8)))
        return Self.constantTimeEquals(digest, expectedTokenDigest)
    }

    static func bearerToken(from authorization: String?) -> String? {
        guard let authorization else { return nil }
        let trimmed = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "Bearer "
        guard trimmed.count > scheme.count, trimmed.lowercased().hasPrefix(scheme.lowercased()) else {
            return nil
        }
        let token = trimmed.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Compares two byte strings without short-circuiting on the first mismatch.
    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

enum CLIServeSecurity {
    /// Normalizes the bind host for the IPv4 socket layer; `localhost` binds `127.0.0.1`.
    static func bindHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased() == "localhost" ? "127.0.0.1" : trimmed
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" {
            return true
        }
        if normalized.hasPrefix("127.") {
            return true
        }
        return normalized == "0:0:0:0:0:0:0:1"
    }

    static func isWildcardHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "0.0.0.0" || normalized == "::" || normalized == "[::]"
    }

    static func isSupportedIPv4BindHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = UInt8(part)
            else {
                return false
            }
            return String(value) == part
        }
    }

    /// Host header values the server accepts for a given bind host: loopback names for
    /// loopback binds, any host for wildcard binds (clients reach those through any of
    /// the machine's addresses), and loopback plus the configured name otherwise.
    static func allowedHosts(forBindHost bindHost: String) -> CLILocalHTTPAllowedHosts {
        let normalized = bindHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
            || normalized == "[::1]" || normalized == "0:0:0:0:0:0:0:1"
        {
            return .loopbackOnly
        }
        if self.isWildcardHost(bindHost) {
            return .any
        }
        return .loopbackAnd([normalized])
    }
}

enum CLIServeStartupError: LocalizedError, Equatable {
    case missingDashboardToken(host: String)
    case plainHTTPNotAccepted(host: String)

    var errorDescription: String? {
        switch self {
        case let .missingDashboardToken(host):
            "--dashboard-token (or CODEXBAR_DASHBOARD_TOKEN) is required for non-loopback --host '\(host)'."
        case let .plainHTTPNotAccepted(host):
            "Refusing to serve the dashboard token over cleartext HTTP on non-loopback --host '\(host)'. "
                + "Pass --allow-plain-http to accept that the bearer token crosses the network "
                + "unencrypted on every request."
        }
    }
}

extension CodexBarCLI {
    /// Startup validation for `codexbar serve` binding and dashboard-token flags.
    /// On non-loopback binds the token guards every data route (`/usage`, `/cost`,
    /// `/dashboard/v1/snapshot`); `/health` is always open.
    ///
    /// | bind host    | token   | --allow-plain-http | result                                     |
    /// |--------------|---------|--------------------|--------------------------------------------|
    /// | loopback     | absent  | any                | serve; snapshot route 401s                 |
    /// | loopback     | present | any                | serve; snapshot gated by token             |
    /// | non-loopback | absent  | any                | error: token required                      |
    /// | non-loopback | present | absent             | error: pass --allow-plain-http             |
    /// | non-loopback | present | present            | serve; all data routes gated; log warning  |
    static func validateServeStartup(
        host: String,
        hasConfiguredBearer: Bool,
        allowPlainHTTP: Bool) -> CLIServeStartupError?
    {
        guard !CLIServeSecurity.isLoopbackHost(host) else { return nil }
        guard hasConfiguredBearer else { return .missingDashboardToken(host: host) }
        guard allowPlainHTTP else { return .plainHTTPNotAccepted(host: host) }
        return nil
    }
}
