#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Persistent cache for AWS Cost Explorer responses.
///
/// AWS bills $0.01 per `GetCostAndUsage` request, while Cost Explorer data only refreshes a few times a day.
/// Without a cache every provider refresh (adaptive timer, menu open, cost-history scan) pays for fresh,
/// identical numbers. Responses are kept on disk so an app relaunch does not re-query either.
///
/// The cache holds raw response pages (service names and dollar amounts, no credentials). Keys are a SHA-256 of
/// the credential identity (access key ID, or profile name), the endpoint, and the query (granularity and time
/// period), so changing credentials or the query never serves another account's numbers.
final class BedrockCostExplorerCache: @unchecked Sendable {
    static let intervalHoursKey = "CODEXBAR_BEDROCK_COST_CACHE_HOURS"
    static let defaultIntervalHours: Double = 6
    private static let maximumEntryAge: TimeInterval = 48 * 3600

    private struct Entry: Codable {
        let fetchedAt: Date
        let pages: [Data]
    }

    private struct Store: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    /// Process-wide cache backed by `~/Library/Application Support/CodexBar/BedrockCostExplorerCache/cache.json`.
    /// A custom `CODEXBAR_BEDROCK_API_URL` endpoint is not billed Cost Explorer, so the shared cache skips it
    /// (this also keeps stubbed endpoints in tests away from the user's cache file).
    static let shared = BedrockCostExplorerCache(
        fileURL: BedrockCostExplorerCache.defaultURL(),
        cachesEndpointOverrides: false)
    /// Never reads or writes; every call goes to AWS. For tests and explicit opt-out.
    static let disabled = BedrockCostExplorerCache(fileURL: nil)

    let cachesEndpointOverrides: Bool
    private let fileURL: URL?
    private let lock = NSLock()
    private var memory: Store?

    init(fileURL: URL?, cachesEndpointOverrides: Bool = true) {
        self.fileURL = fileURL
        self.cachesEndpointOverrides = cachesEndpointOverrides
    }

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("CodexBar/BedrockCostExplorerCache/cache.json", isDirectory: false)
    }

    /// Minimum seconds between Cost Explorer queries for one key. Zero (or an unparsable-negative value) disables
    /// the cache; unset or invalid falls back to the default.
    static func interval(environment: [String: String]) -> TimeInterval {
        guard let raw = SettingsValue.cleaned(environment[self.intervalHoursKey]),
              let hours = Double(raw), hours.isFinite, hours >= 0
        else {
            return self.defaultIntervalHours * 3600
        }
        return hours * 3600
    }

    /// Identity of the AWS account the request is signed for. Profile mode uses the profile name because the
    /// exported access key rotates with every SSO/STS refresh and must not invalidate the cache.
    static func identity(
        credentials: BedrockAWSSigner.Credentials,
        environment: [String: String]) -> String
    {
        if BedrockSettingsReader.authMode(environment: environment) == .profile,
           let profile = BedrockSettingsReader.profile(environment: environment)
        {
            return "profile:\(profile)"
        }
        return "key:\(credentials.accessKeyID)"
    }

    static func key(
        identity: String,
        endpoint: String,
        granularity: String,
        startDate: String,
        endDate: String) -> String
    {
        let material = [identity, endpoint, granularity, startDate, endDate].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cached pages younger than `interval`, else nil.
    func pages(forKey key: String, interval: TimeInterval, now: Date = Date()) -> [Data]? {
        guard self.fileURL != nil, interval > 0 else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.loadLocked().entries[key] else { return nil }
        let age = now.timeIntervalSince(entry.fetchedAt)
        guard age >= 0, age < interval else { return nil }
        return entry.pages
    }

    func store(pages: [Data], forKey key: String, now: Date = Date()) {
        guard let fileURL = self.fileURL else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        var store = self.loadLocked()
        store.entries[key] = Entry(fetchedAt: now, pages: pages)
        store.entries = store.entries.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.maximumEntryAge }
        self.memory = store
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try CredentialFileWriter.writePrivate(encoder.encode(store), to: fileURL)
        } catch {
            // Best effort: the in-memory copy still prevents repeat queries within this process.
        }
    }

    private func loadLocked() -> Store {
        if let memory { return memory }
        var loaded = Store()
        if let fileURL = self.fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(Store.self, from: data), decoded.version == 1 {
                loaded = decoded
            }
        }
        self.memory = loaded
        return loaded
    }
}
