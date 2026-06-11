import Foundation

enum ProviderEndpointOverrideError: LocalizedError, Sendable, Equatable {
    case minimax(String)
    case alibabaCodingPlan(String)

    var errorDescription: String? {
        switch self {
        case let .minimax(key):
            "MiniMax endpoint override \(key) is not allowed. " +
                "Use an HTTPS endpoint without user info or encoded host tricks. " +
                "If MINIMAX_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES=true is set, the endpoint must also be MiniMax-owned."
        case let .alibabaCodingPlan(key):
            "Alibaba Coding Plan endpoint override \(key) is not allowed. " +
                "Use an HTTPS endpoint without user info or encoded host tricks. " +
                "If ALIBABA_CODING_PLAN_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES=true is set, " +
                "the endpoint must also be Alibaba-owned."
        }
    }
}

struct ProviderEndpointOverrideValidator: Sendable {
    enum HostPolicy: Sendable {
        case allowAnyHTTPSHost
        case providerOwnedOnly
    }

    private let allowedHosts: Set<String>
    private let allowedDomainSuffixes: Set<String>

    init(allowedHosts: [String] = [], allowedDomainSuffixes: [String] = []) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowedDomainSuffixes = Set(allowedDomainSuffixes.map { $0.lowercased() })
    }

    func validatedHost(_ raw: String?, policy: HostPolicy = .allowAnyHTTPSHost) -> String? {
        guard let raw,
              let url = self.url(from: raw),
              let host = self.validatedDecodedHost(for: url, policy: policy)
        else { return nil }
        return self.hostAuthority(host: host, port: url.port)
    }

    func validatedURL(_ raw: String?, policy: HostPolicy = .allowAnyHTTPSHost) -> URL? {
        guard let raw,
              let url = self.url(from: raw),
              self.validatedDecodedHost(for: url, policy: policy) != nil
        else { return nil }
        return url
    }

    static func normalizedHTTPSURL(from raw: String) -> URL? {
        let url = if Self.hasExplicitURLScheme(raw) {
            URL(string: raw)
        } else {
            URL(string: "https://\(raw)")
        }
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        guard let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              Self.hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url)
        else { return nil }
        return url
    }

    private func url(from raw: String) -> URL? {
        Self.normalizedHTTPSURL(from: raw)
    }

    private static func hasExplicitURLScheme(_ raw: String) -> Bool {
        guard let colonIndex = raw.firstIndex(of: ":") else { return false }
        if raw[colonIndex...].hasPrefix("://") { return true }

        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }),
           colonIndex > authorityEnd
        {
            return false
        }

        let afterColon = raw.index(after: colonIndex)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { Set<Character>(["/", "?", "#"]).contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
            return false
        }

        let scheme = raw[..<colonIndex]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0) }
    }

    private func hostAuthority(host: String, port: Int?) -> String {
        let authorityHost = host.contains(":") ? "[\(host)]" : host
        guard let port else { return authorityHost }
        return "\(authorityHost):\(port)"
    }

    private func validatedDecodedHost(for url: URL, policy: HostPolicy) -> String? {
        guard let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              Self.hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url)
        else { return nil }

        switch policy {
        case .allowAnyHTTPSHost:
            return decodedHost
        case .providerOwnedOnly:
            let isAllowedHost = self.allowedHosts.contains(decodedHost)
            let isAllowedSuffix = self.allowedDomainSuffixes.contains { suffix in
                decodedHost == suffix || decodedHost.hasSuffix(".\(suffix)")
            }
            guard isAllowedHost || isAllowedSuffix else { return nil }
            return decodedHost
        }
    }

    private static func hostHasNoEncodedDelimiters(_ encodedHost: String, decodedHost: String, url: URL) -> Bool {
        if decodedHost.contains(":") {
            guard encodedHost == decodedHost,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["),
                  componentHost.hasSuffix("]")
            else { return false }

            let address = componentHost.dropFirst().dropLast()
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }

        let decodedDelimiters = CharacterSet(charactersIn: "/\\?#@:")
        guard decodedHost.rangeOfCharacter(from: decodedDelimiters) == nil else { return false }

        let encodedDelimiters = ["%2f", "%5c", "%3f", "%23", "%40", "%3a"]
        return !encodedDelimiters.contains { encodedHost.contains($0) }
    }
}
