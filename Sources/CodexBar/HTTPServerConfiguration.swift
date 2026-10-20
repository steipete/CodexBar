import CodexBarCore
import Foundation

/// Machine-local settings: deliberately separate from provider config, sync, and exports.
struct HTTPServerConfiguration: Codable, Equatable {
    var enabled = false
    var host = "127.0.0.1"
    var port = 8080
    var token = ""
    var refreshInterval = 60.0
    var requestTimeout = 30.0
    var allAccounts = false
    var identity = "redacted"
    var allowPlainHTTP = false

    var bindHost: String {
        let trimmed = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased() == "localhost" ? "127.0.0.1" : trimmed
    }

    var isLoopback: Bool {
        self.bindHost.hasPrefix("127.")
    }

    var url: String {
        "http://\(self.bindHost):\(self.port)/"
    }

    var validationError: String? {
        let parts = self.bindHost.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0).map { String($0) } == String($0) }) else {
            return "Enter localhost or an IPv4 address."
        }
        guard (1...65535).contains(self.port) else { return "Port must be between 1 and 65535." }
        guard self.refreshInterval.isFinite, self.refreshInterval >= 0,
              self.requestTimeout.isFinite, self.requestTimeout >= 0
        else { return "Cache interval and request timeout must be finite, nonnegative seconds." }
        guard ["redacted", "full"].contains(self.identity) else { return "Choose an identity privacy mode." }
        guard !self.token.isEmpty, self.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            return "Generate a token or enter a nonempty token without spaces."
        }
        guard self.isLoopback || self.allowPlainHTTP else {
            return "Accept the unencrypted HTTP warning before listening outside this Mac."
        }
        return nil
    }

    var arguments: [String] {
        var result = [
            "serve",
            "--host",
            self.bindHost,
            "--port",
            String(self.port),
            "--refresh-interval",
            String(self.refreshInterval),
            "--request-timeout",
            String(self.requestTimeout),
            "--identity",
            self.identity,
        ]
        if self.allAccounts { result.append("--all-accounts") }
        if self.allowPlainHTTP { result.append("--allow-plain-http") }
        return result
    }

    static func generateToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try CredentialFileWriter.writePrivate(JSONEncoder().encode(self), to: url)
    }
}
