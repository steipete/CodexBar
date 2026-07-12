import CodexBarCore
import Foundation

struct PlanUtilizationSeriesName: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let session: Self = "session"
    static let weekly: Self = "weekly"
    static let opus: Self = "opus"

    func canonicalWindowMinutes(_ windowMinutes: Int) -> Int {
        switch self {
        case .session where (295...305).contains(windowMinutes):
            300
        case .weekly where (10070...10090).contains(windowMinutes):
            10080
        default:
            windowMinutes
        }
    }
}

struct PlanUtilizationHistoryEntry: Codable, Equatable, Hashable, Sendable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct PlanUtilizationSeriesHistory: Codable, Equatable, Sendable {
    let name: PlanUtilizationSeriesName
    let windowMinutes: Int
    let entries: [PlanUtilizationHistoryEntry]

    init(name: PlanUtilizationSeriesName, windowMinutes: Int, entries: [PlanUtilizationHistoryEntry]) {
        self.name = name
        self.windowMinutes = windowMinutes
        self.entries = entries.sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            let lhsReset = lhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            let rhsReset = rhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            return lhsReset < rhsReset
        }
    }

    var latestCapturedAt: Date? {
        self.entries.last?.capturedAt
    }
}

struct PlanUtilizationHistoryBuckets: Equatable, Sendable {
    var preferredAccountKey: String?
    var unscoped: [PlanUtilizationSeriesHistory] = []
    var accounts: [String: [PlanUtilizationSeriesHistory]] = [:]

    func histories(for accountKey: String?) -> [PlanUtilizationSeriesHistory] {
        guard let accountKey, !accountKey.isEmpty else { return self.unscoped }
        return self.accounts[accountKey] ?? []
    }

    mutating func setHistories(_ histories: [PlanUtilizationSeriesHistory], for accountKey: String?) {
        let sorted = Self.sortedHistories(histories)
        guard let accountKey, !accountKey.isEmpty else {
            self.unscoped = sorted
            return
        }
        if sorted.isEmpty {
            self.accounts.removeValue(forKey: accountKey)
        } else {
            self.accounts[accountKey] = sorted
        }
    }

    var isEmpty: Bool {
        self.unscoped.isEmpty && self.accounts.values.allSatisfy(\.isEmpty)
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        histories.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }
}

private struct ProviderHistoryFile: Codable, Sendable {
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
}

private struct ProviderHistoryDocument: Codable, Sendable {
    let version: Int
    let preferredAccountKey: String?
    let unscoped: [PlanUtilizationSeriesHistory]
    let accounts: [String: [PlanUtilizationSeriesHistory]]
}

struct PlanUtilizationHistoryStore: Sendable {
    fileprivate static let providerSchemaVersion = 1

    let directoryURL: URL?

    init(directoryURL: URL? = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    static func defaultAppSupport() -> Self {
        Self()
    }

    func load() -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        self.loadProviderFiles()
    }

    /// Loads the persisted histories on a utility-priority detached task.
    ///
    /// The on-disk decode is synchronous I/O + JSON parsing that can take
    /// ~150 ms for mature two-year histories and must not run on the app
    /// startup main thread. The returned dictionary is safe to apply on the
    /// main actor once decoding completes.
    func loadAsync() async -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        await Task.detached(priority: .utility) { self.load() }.value
    }

    func save(_ providers: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        guard let directoryURL = self.directoryURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]

            for provider in UsageProvider.allCases {
                let fileURL = self.providerFileURL(for: provider)
                let buckets = providers[provider] ?? PlanUtilizationHistoryBuckets()
                let unscoped = Self.sortedHistories(buckets.unscoped)
                let accounts = Self.sortedAccounts(buckets.accounts)
                guard !unscoped.isEmpty || !accounts.isEmpty else {
                    try? FileManager.default.removeItem(at: fileURL)
                    continue
                }

                let payload = ProviderHistoryDocument(
                    version: Self.providerSchemaVersion,
                    preferredAccountKey: buckets.preferredAccountKey,
                    unscoped: unscoped,
                    accounts: accounts)
                let data = try encoder.encode(payload)
                try data.write(to: fileURL, options: Data.WritingOptions.atomic)
            }
        } catch {
            // Best-effort persistence only.
        }
    }

    private func loadProviderFiles() -> [UsageProvider: PlanUtilizationHistoryBuckets] {
        guard self.directoryURL != nil else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]

        for provider in UsageProvider.allCases {
            let fileURL = self.providerFileURL(for: provider)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? decoder.decode(ProviderHistoryDocument.self, from: data)
            else {
                continue
            }

            let history = ProviderHistoryFile(
                preferredAccountKey: decoded.preferredAccountKey,
                unscoped: decoded.unscoped,
                accounts: decoded.accounts)
            output[provider] = Self.decodeProvider(history)
        }

        return output
    }

    private static func decodeProviders(
        _ providers: [String: ProviderHistoryFile]) -> [UsageProvider: PlanUtilizationHistoryBuckets]
    {
        var output: [UsageProvider: PlanUtilizationHistoryBuckets] = [:]
        for (rawProvider, providerHistory) in providers {
            guard let provider = UsageProvider(rawValue: rawProvider) else { continue }
            output[provider] = Self.decodeProvider(providerHistory)
        }
        return output
    }

    private static func decodeProvider(_ providerHistory: ProviderHistoryFile) -> PlanUtilizationHistoryBuckets {
        PlanUtilizationHistoryBuckets(
            preferredAccountKey: providerHistory.preferredAccountKey,
            unscoped: self.sortedHistories(providerHistory.unscoped),
            accounts: Dictionary(
                uniqueKeysWithValues: providerHistory.accounts.compactMap { accountKey, histories in
                    let sorted = Self.sortedHistories(histories)
                    guard !sorted.isEmpty else { return nil }
                    return (accountKey, sorted)
                }))
    }

    private static func sortedAccounts(
        _ accounts: [String: [PlanUtilizationSeriesHistory]]) -> [String: [PlanUtilizationSeriesHistory]]
    {
        Dictionary(
            uniqueKeysWithValues: accounts.compactMap { accountKey, histories in
                let sorted = Self.sortedHistories(histories)
                guard !sorted.isEmpty else { return nil }
                return (accountKey, sorted)
            })
    }

    private static func sortedHistories(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
        self.sanitizedHistories(histories).sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private static func sanitizedHistories(_ histories: [PlanUtilizationSeriesHistory])
    -> [PlanUtilizationSeriesHistory] {
        histories.filter { history in
            history.windowMinutes > 0 && !history.entries.isEmpty
        }
    }

    private static func defaultDirectoryURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        return dir.appendingPathComponent("history", isDirectory: true)
    }

    private func providerFileURL(for provider: UsageProvider) -> URL {
        let directoryURL = self.directoryURL ?? URL(fileURLWithPath: "/dev/null", isDirectory: true)
        return directoryURL.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }
}

extension ProviderHistoryDocument {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == PlanUtilizationHistoryStore.providerSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported provider history schema version \(version)")
        }
        self.version = version
        self.preferredAccountKey = try container.decodeIfPresent(String.self, forKey: .preferredAccountKey)
        self.unscoped = try container.decode([PlanUtilizationSeriesHistory].self, forKey: .unscoped)
        self.accounts = try container.decode([String: [PlanUtilizationSeriesHistory]].self, forKey: .accounts)
    }
}

/// One-shot synchronization primitive used by `UsageStore.init` to defer the
/// utility-priority plan-utilization history load until a test chooses to
/// release it. The default `nil` gate is open and the load proceeds immediately.
///
/// Used to verify that `UsageStore.init` returns before disk I/O completes and
/// that the history is applied exactly once after the gate opens.
final class PlanUtilizationHistoryLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var _isOpen: Bool = false

    init() {}

    var isOpen: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._isOpen
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self._isOpen {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuations.append(continuation)
            self.lock.unlock()
        }
    }

    func open() {
        self.lock.lock()
        self._isOpen = true
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    /// Resumes every pending waiter without marking the gate as open. Use this
    /// to release a waiter that is being cancelled so its `withCheckedContinuation`
    /// does not leak the suspended task, continuation, and the gate itself.
    /// Pending waiters resume as if `open()` had been called; subsequent
    /// `wait()` calls still observe the gate as closed, so a test that calls
    /// `cancelAll()` and then `open()` gets the natural reopen semantics.
    func cancelAll() {
        self.lock.lock()
        let pending = self.continuations
        self.continuations.removeAll()
        self.lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
