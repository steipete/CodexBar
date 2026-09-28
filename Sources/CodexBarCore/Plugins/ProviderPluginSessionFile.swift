import Foundation

/// Reads the native token-file shape without granting scripts filesystem or credential access.
final class ProviderPluginSessionFile: @unchecked Sendable {
    private static let lock = NSLock()
    private let url: URL
    private let policy: ProviderPluginCookiePolicy.SessionFile

    init(provider: UsageProvider, policy: ProviderPluginCookiePolicy.SessionFile, url: URL? = nil) {
        self.url = url ?? ProviderSessionStoreFile.url(for: provider.rawValue + "-session.json")
        self.policy = policy
    }

    func read() -> [String: String]? {
        Self.lock.withLock { self.load() }
    }

    private func load() -> [String: String]? {
        CredentialFileWriter.repairPermissions(at: self.url)
        guard let data = try? Data(contentsOf: self.url), data.count <= 65536,
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let token = values[self.policy.tokenField], !token.isEmpty
        else { return nil }
        return values
    }

    func header(_ values: [String: String]) -> String? {
        values[self.policy.tokenField].map { "\(self.policy.cookieName)=\($0)" }
    }

    func values(header: String?, source: String) -> [String: String]? {
        guard let header, let token = CookieHeaderNormalizer.pairs(from: header)
            .first(where: { $0.name == self.policy.cookieName })?.value else { return nil }
        return [self.policy.tokenField: token, "sourceLabel": source]
    }

    func replace(expected: [String: String]?, header: String?, source: String) {
        Self.lock.withLock {
            guard self.load() == expected else { return }
            guard let values = self.values(header: header, source: source),
                  let data = try? JSONEncoder().encode(values)
            else {
                try? FileManager.default.removeItem(at: self.url)
                return
            }
            try? CredentialFileWriter.writePrivate(data, to: self.url)
        }
    }
}
