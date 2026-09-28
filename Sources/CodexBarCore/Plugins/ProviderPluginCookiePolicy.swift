import Foundation

/// Bundled-only authority for selecting and retaining a single browser profile.
public struct ProviderPluginCookiePolicy: Sendable {
    public enum Selection: String, Sendable {
        case requestURL = "request-url"
        case rankedSourceDomains = "ranked-source-domains"
    }

    public enum Persistence: String, Sendable {
        case nonpersistent
        case validatedSingleEntry = "validated-single-entry"
    }

    public enum Imports: String, Sendable {
        case appInteractive = "app-interactive"
        case accessGated = "access-gated"
    }

    public enum MissingCookies: String, Sendable {
        case reject
        case omit
    }

    public struct SessionFile: Sendable {
        let tokenField: String
        let cookieName: String
    }

    let selection: Selection
    let cache: Persistence
    let sourceDomains: [String]
    let requiredCookies: Set<String>
    let requestHosts: Set<String>
    let sessionFile: SessionFile?
    let missingCookies: MissingCookies
    let imports: Imports

    init(_ value: any ProviderPluginValue, domains: Set<String>, endpoints: Set<ProviderPluginEndpoint>) throws {
        let invalid = ProviderPluginError.invalidManifest("invalid bundled cookiePolicy")
        guard value.isObject, !value.isArray,
              try Set(value.propertyNames()).isSubset(of: [
                  "selection", "cache", "sourceDomains", "requiredCookies", "sessionFile", "missingCookies", "imports",
              ]),
              let selection = value.property("selection"), selection.isString,
              let selection = Selection(rawValue: selection.stringValue()),
              let cache = value.property("cache"), cache.isString,
              let cache = Persistence(rawValue: cache.stringValue())
        else { throw invalid }
        if let missing = value.property("missingCookies"), !missing.isUndefined {
            guard missing.isString, let policy = MissingCookies(rawValue: missing.stringValue()) else { throw invalid }
            self.missingCookies = policy
        } else {
            self.missingCookies = .reject
        }
        if let imports = value.property("imports"), !imports.isUndefined {
            guard imports.isString, let policy = Imports(rawValue: imports.stringValue()) else { throw invalid }
            self.imports = policy
        } else {
            self.imports = .appInteractive
        }
        self.selection = selection
        self.cache = cache
        self.sourceDomains = try Self.strings(value.property("sourceDomains"))
        self.requiredCookies = try Set(Self.strings(value.property("requiredCookies")))
        self.requestHosts = Set(endpoints.compactMap { endpoint in
            guard case let .fixed(origin) = endpoint, let url = URL(string: origin), url.scheme == "https" else {
                return nil
            }
            return url.host
        })
        guard !self.requestHosts.isEmpty,
              self.sourceDomains.count == Set(self.sourceDomains).count,
              Set(self.sourceDomains).isSubset(of: domains),
              self.requiredCookies
                  .allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil }),
                  selection == .requestURL ? self.sourceDomains.isEmpty : !self.sourceDomains.isEmpty
        else { throw invalid }
        if let file = value.property("sessionFile"), !file.isUndefined {
            guard cache == .validatedSingleEntry, selection == .rankedSourceDomains,
                  self.requestHosts.count == 1, file.isObject, !file.isArray,
                  try Set(file.propertyNames()) == ["tokenField", "cookieName"],
                  let field = file.property("tokenField"), field.isString,
                  field.stringValue().range(of: #"^[A-Za-z][A-Za-z0-9]{0,63}$"#, options: .regularExpression) != nil,
                  let cookie = file.property("cookieName"), cookie.isString,
                  self.requiredCookies.contains(cookie.stringValue())
            else { throw invalid }
            self.sessionFile = SessionFile(tokenField: field.stringValue(), cookieName: cookie.stringValue())
        } else {
            self.sessionFile = nil
        }
    }

    func allowsImportAttempt(runtime: ProviderRuntime, interaction: ProviderInteraction) -> Bool {
        self.imports == .accessGated || (runtime == .app && interaction == .userInitiated)
    }

    private static func strings(_ value: (any ProviderPluginValue)?) throws -> [String] {
        guard let value, !value.isUndefined else { return [] }
        guard value.isArray, let count = value.property("length"), (1...16).contains(count.int32Value()) else {
            throw ProviderPluginError.invalidManifest("cookie policy lists must contain 1-16 strings")
        }
        return try (0..<Int(count.int32Value())).map { index in
            guard let item = value.element(at: index), item.isString else {
                throw ProviderPluginError.invalidManifest("cookie policy lists must contain strings")
            }
            return item.stringValue()
        }
    }

    func selected(_ records: [ProviderPluginCookieRecord], domain: String, now: Date = Date())
        -> [ProviderPluginCookieRecord]?
    {
        let records = records.filter { $0.expires.map { $0 > now } ?? true }
        let selected: [ProviderPluginCookieRecord]
        switch self.selection {
        case .requestURL:
            selected = records.sorted { lhs, rhs in
                // Browser store merging returns dictionary values; keep the credential identity stable.
                [lhs.domain, lhs.path, lhs.name, String(lhs.hostOnly), lhs.value]
                    .lexicographicallyPrecedes([rhs.domain, rhs.path, rhs.name, String(rhs.hostOnly), rhs.value])
            }
        case .rankedSourceDomains:
            guard self.requestHosts.contains(domain) else { return nil }
            var best: [String: ProviderPluginCookieRecord] = [:]
            for source in self.sourceDomains {
                for record in records where record.domain == source && best[record.name] == nil {
                    best[record.name] = record.bound(to: domain)
                }
            }
            selected = best.keys.sorted().compactMap { best[$0] }
        }
        guard self.requiredCookies.isSubset(of: Set(selected.map(\.name))) else { return nil }
        return selected.isEmpty ? nil : selected
    }
}
