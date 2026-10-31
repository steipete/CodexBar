import Foundation

/// Machine-local SSH hosts and spend consent share one canonical defaults transaction.
public enum HostPreferences {
    public enum Error: Swift.Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case let .invalid(message): message
            }
        }
    }

    public static var lockURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar/hosts.lock", isDirectory: false)
    }

    public static func update<Result>(
        in defaults: UserDefaults,
        lockURL: URL? = Self.lockURL,
        operation: (inout State) throws -> Result) throws -> (state: State, result: Result)
    {
        try ManagedCodexAccountLock.withLock(at: lockURL, wait: true) {
            defaults.synchronize()
            let raw = defaults.string(forKey: "agentSessionsManualHosts") ?? ""
            var state = State(
                manualHosts: raw.isEmpty ? [] : raw.components(separatedBy: ","),
                costUsageHosts: defaults.stringArray(forKey: "costUsageHosts") ?? [])
            state.filterSelection()
            let previous = state
            let result = try operation(&state)
            state.filterSelection()
            if state != previous {
                defaults.set(state.manualTokens.joined(separator: ","), forKey: "agentSessionsManualHosts")
                defaults.set(state.costUsageHosts, forKey: "costUsageHosts")
                defaults.synchronize()
            }
            return (state, result)
        }
    }

    public static func adding(
        _ rawHost: String,
        to state: State,
        cost: Bool)
        throws -> Mutation
    {
        guard let host = RemoteSessionFetcher.sanitizedHosts([rawHost]).first else {
            throw Error.invalid(RemoteCodexCostError.invalidHost.localizedDescription)
        }
        try RemoteCodexCostFetcher.validateHost(host)
        var next = state
        var changed = false
        // Keep the stored spelling; `devbox` and a stored `DevBox` are one host, and a
        // retry with the same spelling changes nothing.
        let canonical: String
        if let existing = next.manualHosts.first(where: {
            RemoteSessionFetcher.hostIdentityKey($0) == RemoteSessionFetcher.hostIdentityKey(host)
        }) {
            guard (try? RemoteCodexCostFetcher.validateHost(existing)) != nil else {
                throw Error.invalid(
                    "Stored host \(existing) is invalid. Remove it, then add \(host) again.")
            }
            canonical = existing
        } else {
            canonical = host
            next.manualTokens.append(host)
            changed = true
        }
        if cost,
           // Spend members are valid manual hosts spelled exactly as stored, as the app keeps them.
           !next.costUsageHosts.contains(canonical)
        {
            next.costUsageHosts.append(canonical)
            changed = true
        }
        return Mutation(state: next, changed: changed, host: canonical)
    }

    public static func removing(
        _ rawHost: String,
        from state: State,
        costOnly: Bool)
        throws -> Mutation
    {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(",") else {
            throw Error.invalid("Remove one nonempty stored host token at a time.")
        }
        var next = state
        var changed = false
        let spend = next.costUsageHosts
        let key = RemoteSessionFetcher.hostIdentityKey(host)
        let canonical = next.listedHosts.first {
            RemoteSessionFetcher.hostIdentityKey($0) == key
        } ?? host
        if costOnly {
            next.costUsageHosts = spend.filter { RemoteSessionFetcher.hostIdentityKey($0) != key }
            changed = spend != next.costUsageHosts
        } else {
            // Removal may address hosts Settings typed without strict validation.
            let tokens = next.manualTokens
            next.manualTokens = tokens.filter {
                RemoteSessionFetcher.hostIdentityKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) != key
            }
            changed = tokens != next.manualTokens
            // Dropping a manual host drops its spend membership, as the app's setter does.
            let candidates = Set(RemoteCodexCostFetcher.costUsageCandidates(in: next.manualTokens))
            next.costUsageHosts = spend.filter(candidates.contains)
            changed = changed || spend != next.costUsageHosts
        }
        return Mutation(state: next, changed: changed, host: canonical)
    }

    /// Merge only the editor's changes; a host added after the field loaded stays configured.
    public static func editing(_ state: State, baseline: String, draft: String) -> State {
        guard baseline != draft else { return state }
        let before = baseline.components(separatedBy: ",")
        let after = draft.isEmpty ? [] : draft.components(separatedBy: ",")
        let key: (String) -> String = {
            RemoteSessionFetcher.hostIdentityKey($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let oldGroups = Dictionary(grouping: before, by: key)
        let newGroups = Dictionary(grouping: after, by: key)
        let current = Dictionary(grouping: state.manualTokens, by: key)
        var tokens: [String] = []
        var emitted = Set<String>()
        for token in after {
            let identity = key(token)
            guard emitted.insert(identity).inserted else { continue }
            if oldGroups[identity] == newGroups[identity] || oldGroups[identity] == nil {
                // Unedited hosts keep their latest raw spelling; a concurrent deletion stays deleted.
                tokens += current[identity] ?? (oldGroups[identity] == nil ? newGroups[identity] ?? [] : [])
            } else {
                tokens += newGroups[identity] ?? []
            }
        }
        tokens += state.manualTokens.filter { oldGroups[key($0)] == nil && newGroups[key($0)] == nil }
        var next = state
        next.manualTokens = tokens
        next.filterSelection()
        return next
    }

    public struct Mutation: Sendable {
        public let state: State
        public let changed: Bool
        public let host: String

        public init(state: State, changed: Bool, host: String) {
            self.state = state
            self.changed = changed
            self.host = host
        }
    }

    public struct State: Equatable, Sendable {
        /// Comma tokens exactly as stored; a write changes only the entries a command addressed.
        public var manualTokens: [String] = []
        public var costUsageHosts: [String] = []

        /// The sanitized, deduplicated host list the app itself reads from the stored setting.
        public var manualHosts: [String] {
            RemoteSessionFetcher.sanitizedHosts(self.manualTokens)
        }

        /// Include rejected Settings tokens in the inventory, preserving the first stored spelling.
        public var listedHosts: [String] {
            var seen = Set<String>()
            return self.manualTokens.compactMap { token in
                let host = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty,
                      seen.insert(RemoteSessionFetcher.hostIdentityKey(host)).inserted else { return nil }
                return host
            }
        }

        public mutating func setCostUsage(_ host: String, enabled: Bool) {
            let identity = RemoteSessionFetcher.hostIdentityKey(host)
            if enabled {
                if let canonical = self.manualHosts.first(where: {
                    RemoteSessionFetcher.hostIdentityKey($0) == identity
                }), !self.costUsageHosts.contains(canonical) { self.costUsageHosts.append(canonical) }
            } else {
                self.costUsageHosts.removeAll { RemoteSessionFetcher.hostIdentityKey($0) == identity }
            }
            self.filterSelection()
        }

        mutating func filterSelection() {
            self.costUsageHosts = RemoteCodexCostFetcher.selectedCostUsageHosts(
                manualHosts: self.manualTokens, storedSelection: self.costUsageHosts)
        }

        public init(manualHosts: [String] = [], costUsageHosts: [String] = []) {
            self.manualTokens = manualHosts
            self.costUsageHosts = costUsageHosts
        }
    }
}
