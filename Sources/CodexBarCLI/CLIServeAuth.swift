import Foundation

struct CLIServeAuth: Sendable {
    let token: String?
    let pairing: CLIServePairing?

    init(token: String?, pairing: CLIServePairing? = nil) {
        self.token = token
        self.pairing = pairing
    }

    init(dashboardToken: String?, pairing: CLIServePairing? = nil) {
        self.init(token: dashboardToken, pairing: pairing)
    }

    func authorizeDataRequest(_ request: CLILocalHTTPRequest) -> Bool {
        guard let token else {
            guard let pairing else { return true }
            return pairing.authorize(request)
        }
        guard let authorization = request.headers["authorization"] else { return false }
        let normalized = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "Bearer \(token)" { return true }
        return self.pairing?.authorize(request) == true
    }

    func authorizeDashboardRequest(_ request: CLILocalHTTPRequest) -> Bool {
        self.authorizeDataRequest(request)
    }
}

enum CLIServeSecurity {
    static func bindHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "localhost" ? "127.0.0.1" : host
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        if normalized.hasPrefix("127.") { return true }
        return normalized == "0:0:0:0:0:0:0:1"
    }

    static func requiresDashboardToken(host: String) -> Bool {
        !self.isLoopbackHost(host)
    }
}

final class CLIServePairing: @unchecked Sendable {
    struct Challenge: Sendable {
        let id: String
        let code: String
        let token: String
    }

    struct DiscoveryPayload: Encodable {
        let schemaVersion: Int
        let service: String
        let auth: AuthPayload
    }

    struct AuthPayload: Encodable {
        let type: String
        let pairingId: String
        let codeLength: Int
        let expiresInSeconds: Int
    }

    struct ClaimPayload: Encodable {
        let schemaVersion: Int
        let token: String
        let endpoint: String
    }

    enum ClaimOutcome: Sendable {
        case claimed(ClaimPayload)
        case rejected
        case unavailable
    }

    static let maxFailedAttempts = 5
    static let codeLength = 6

    private let lock = NSLock()
    private let announce: @Sendable (String) -> Void
    private var challenge: Challenge
    private var paired = false
    private var failedAttempts = 0

    init(announce: @escaping @Sendable (String) -> Void = { _ in }) {
        self.announce = announce
        self.challenge = Self.makeChallenge()
    }

    /// The code to display next to the server, or nil once pairing is closed.
    func currentCode() -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.isOpenLocked else { return nil }
        return self.challenge.code
    }

    func discoveryPayload() -> DiscoveryPayload? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.isOpenLocked else { return nil }
        return DiscoveryPayload(
            schemaVersion: 1,
            service: "codexbar-dashboard",
            auth: AuthPayload(
                type: "code",
                pairingId: self.challenge.id,
                codeLength: Self.codeLength,
                expiresInSeconds: 0))
    }

    func claim(pairingID: String?, code: String?) -> ClaimOutcome {
        let outcome: ClaimOutcome
        var message: String?

        self.lock.lock()
        if !self.isOpenLocked {
            outcome = .unavailable
        } else if pairingID == self.challenge.id,
                  Self.normalizeCode(code) == self.challenge.code
        {
            self.paired = true
            outcome = .claimed(ClaimPayload(
                schemaVersion: 1,
                token: self.challenge.token,
                endpoint: "/dashboard/v1/snapshot"))
            message = "Dashboard paired. Pairing is now closed.\n"
        } else {
            self.failedAttempts += 1
            if self.failedAttempts >= Self.maxFailedAttempts {
                message = "Too many failed pairing attempts. Pairing disabled until restart.\n"
            } else {
                message = "Pairing attempt rejected (\(self.failedAttempts)/\(Self.maxFailedAttempts)).\n"
            }
            outcome = .rejected
        }
        self.lock.unlock()

        if let message {
            self.announce(message)
        }
        return outcome
    }

    func authorize(_ request: CLILocalHTTPRequest) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.paired else { return false }
        guard let authorization = request.headers["authorization"] else { return false }
        return authorization.trimmingCharacters(in: .whitespacesAndNewlines) == "Bearer \(self.challenge.token)"
    }

    private var isOpenLocked: Bool {
        !self.paired && self.failedAttempts < Self.maxFailedAttempts
    }

    /// Strips separators users may copy from the grouped console output ("481 273").
    private static func normalizeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let digits = code.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private static func makeChallenge() -> Challenge {
        Challenge(
            id: UUID().uuidString,
            code: self.randomCode(),
            token: self.randomToken())
    }

    private static func randomCode() -> String {
        (0..<self.codeLength).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    private static func randomToken() -> String {
        [UUID().uuidString, UUID().uuidString]
            .joined()
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}
