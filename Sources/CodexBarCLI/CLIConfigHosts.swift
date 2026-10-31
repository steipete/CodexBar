import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func hostsCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "hosts",
            abstract: "List or change the SSH hosts the app tracks (macOS)",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "list",
                    abstract: "List tracked SSH hosts",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigHostsListOptions()).flattened()),
                CommandDescriptor(
                    name: "add",
                    abstract: "Track an SSH host",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigHostsAddOptions()).flattened()),
                CommandDescriptor(
                    name: "remove",
                    abstract: "Stop tracking an SSH host",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigHostsRemoveOptions()).flattened()),
            ])
    }

    enum ConfigHostsAction {
        case list
        case add
        case remove
    }

    static func runConfigHosts(_ values: ParsedValues, action: ConfigHostsAction) async {
        let output = CLIOutputPreferences.from(values: values)
        #if os(macOS)
        let domain = values.options["defaultsDomain"]?.last ?? PreferencesDocument.defaultsDomain
        do {
            guard let defaults = UserDefaults(suiteName: domain) else {
                throw PreferencesDocument.Error.invalid("Cannot open preferences domain")
            }
            let result = try Self.configHostsMutation(
                action, host: values.positional.first, cost: values.flags.contains("cost"), in: defaults)
            if result.changed, domain == PreferencesDocument.defaultsDomain {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(PreferencesDocument.importNotification),
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true)
            }
            let next = result.state
            let changed = result.changed
            // Report and check the host as it is stored, never the raw argument.
            let host = result.host
            try Task.checkCancellation()
            switch action {
            case .list:
                var entries = Self.configHostsEntries(next)
                if values.flags.contains("check") {
                    let checks = try await Self.runHostsCheck(entries.map(\.host))
                    for index in entries.indices {
                        entries[index].check = checks[index]
                    }
                }
                if output.format == .json {
                    Self.printJSON(ConfigHostsListResult(hosts: entries), pretty: output.pretty)
                } else {
                    if entries.isEmpty { print("No SSH hosts configured.") }
                    for entry in entries {
                        print(Self.renderConfigHostEntry(entry))
                    }
                }
                Self.exit(
                    code: entries.contains { $0.check?.ok == false } ? .failure : .success,
                    output: output,
                    kind: .provider)
            case .add, .remove:
                var result = ConfigHostsMutationResult(
                    host: host,
                    changed: changed,
                    costUsage: next.costUsageHosts.contains(host),
                    check: nil)
                if values.flags.contains("check") {
                    let checks = try await Self.runHostsCheck([host])
                    result.check = checks.first
                }
                if output.format == .json {
                    Self.printJSON(result, pretty: output.pretty)
                } else {
                    print(Self.renderConfigHostMutation(
                        result,
                        action: action,
                        costOnly: values.flags.contains("cost")))
                }
                Self.exit(
                    code: result.check?.ok == false ? .failure : .success,
                    output: output,
                    kind: .provider)
            }
        } catch is CancellationError {
            Self.exit(code: .failure, message: "Host check cancelled.", output: output, kind: .runtime)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }
        #else
        Self.exit(
            code: .failure,
            message: "Host configuration commands are only available on macOS.",
            output: output,
            kind: .args)
        #endif
    }

    static func configHostsMutation(
        _ action: ConfigHostsAction,
        host: String?,
        cost: Bool,
        in defaults: UserDefaults,
        lockURL: URL? = PreferencesDocument.importLockURL) throws -> ConfigHostsMutation
    {
        try PreferencesDocument.withImportLock(in: defaults, lockURL: action == .list ? nil : lockURL) {
            let state = try Self.configHostsState(in: defaults)
            guard action != .list else { return ConfigHostsMutation(state: state, changed: false, host: "") }
            guard let host, !host.isEmpty else {
                throw PreferencesDocument.Error.invalid("\(action) requires one <host> argument")
            }
            let mutation = action == .add
                ? try Self.addedConfigHost(host, to: state, cost: cost)
                : try Self.removedConfigHost(host, from: state, costOnly: cost)
            if mutation.changed { try Self.queueConfigHosts(mutation.state, in: defaults, lockURL: lockURL) }
            return mutation
        }
    }

    /// One Ctrl-C must cancel the check and reap SSH children, like the cost report.
    private static func runHostsCheck(_ hosts: [String]) async throws -> [ConfigHostsCheckResult] {
        try await CLITerminationSignalMonitor.withTerminationCleanup { try await Self.checkConfigHosts(hosts) }
    }

    // MARK: Pure host-list logic

    /// Hosts as the app resolves them: the persisted comma tokens (kept verbatim so a write
    /// never rewrites entries the command did not address), overridden by any queued CLI
    /// import, with the app's load-time spend filter applied.
    static func configHostsState(in defaults: UserDefaults) throws -> ConfigHostsState {
        // Read the queue before the persisted values: a still-present queue is newer than
        // anything persisted, and if the app consumes it between the two reads, the
        // persisted values read afterwards already include it.
        let pending = try defaults.data(forKey: PreferencesDocument.pendingImportKey)
            .map { try PreferencesDocument(queueData: $0) }
        let manualRaw: String =
            try pending?.value("agentSessionsManualHosts")
            ?? defaults.string(forKey: "agentSessionsManualHosts")
            ?? ""
        let costRaw: [String] =
            try pending?.value("costUsageHosts")
            ?? defaults.stringArray(forKey: "costUsageHosts")
            ?? []
        let tokens = manualRaw.isEmpty ? [] : manualRaw.components(separatedBy: ",")
        return ConfigHostsState(
            manualHosts: tokens,
            costUsageHosts: RemoteCodexCostFetcher.selectedCostUsageHosts(
                manualHosts: tokens, storedSelection: costRaw))
    }

    static func configHostsEntries(_ state: ConfigHostsState) -> [ConfigHostsEntry] {
        state.listedHosts.map { host in
            ConfigHostsEntry(
                host: host,
                valid: (try? RemoteCodexCostFetcher.validateHost(host)) != nil,
                costUsage: state.costUsageHosts.contains(host),
                check: nil)
        }
    }

    static func addedConfigHost(
        _ rawHost: String,
        to state: ConfigHostsState,
        cost: Bool)
        throws -> ConfigHostsMutation
    {
        guard let host = RemoteSessionFetcher.sanitizedHosts([rawHost]).first else {
            throw PreferencesDocument.Error.invalid(RemoteCodexCostError.invalidHost.localizedDescription)
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
                throw PreferencesDocument.Error.invalid(
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
        return ConfigHostsMutation(state: next, changed: changed, host: canonical)
    }

    static func removedConfigHost(
        _ rawHost: String,
        from state: ConfigHostsState,
        costOnly: Bool)
        throws -> ConfigHostsMutation
    {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(","),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PreferencesDocument.Error
                .invalid("Remove one stored host token at a time, without control characters.")
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
        return ConfigHostsMutation(state: next, changed: changed, host: canonical)
    }

    static func queueConfigHosts(
        _ state: ConfigHostsState,
        in defaults: UserDefaults,
        lockURL: URL? = PreferencesDocument.importLockURL) throws
    {
        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", state.manualTokens.joined(separator: ","))
        try document.set("costUsageHosts", state.costUsageHosts)
        try document.queueImport(in: defaults, lockURL: lockURL)
    }

    // MARK: Host check

    static let hostCheckFailureMessage =
        "Could not check the host over SSH. Verify noninteractive SSH access and a trusted host key, " +
        "and that the host's CodexBar CLI supports --identified-only."

    /// Reuses the one-shot identified-usage SSH fetch over today's UTC window so far. The fetch
    /// itself validates the host and reports an outdated remote CLI, so the error keeps its cause.
    static func checkConfigHosts(
        _ hosts: [String],
        now: @Sendable () -> Date = { Date() },
        fetch: (@Sendable (String) async throws -> Void)? = nil)
        async throws -> [ConfigHostsCheckResult]
    {
        let end = Int64((now().timeIntervalSince1970 * 1000).rounded())
        guard let start = CodexIdentifiedCollection.window(days: 1, endUnixMs: end) else {
            throw PreferencesDocument.Error.invalid("Invalid UTC history window.")
        }
        let resolvedFetch: @Sendable (String) async throws -> Void = fetch ?? { host in
            _ = try await RemoteCodexCostFetcher().fetchIdentifiedUsage(
                host: host, historyDays: 1, startUnixMs: start, endUnixMs: end)
        }
        var results: [ConfigHostsCheckResult] = []
        for host in hosts {
            try Task.checkCancellation()
            do {
                try RemoteCodexCostFetcher.validateHost(host)
                try await resolvedFetch(host)
                results.append(ConfigHostsCheckResult(ok: true, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                results.append(ConfigHostsCheckResult(ok: false, error: Self.hostCheckError(error)))
            }
        }
        return results
    }

    /// Keep the named cause: an invalid host and an outdated remote CLI stay distinguishable.
    /// `.unavailable` names `--summary-only`, which this identified-usage check never sends.
    static func hostCheckError(_ error: Error) -> String {
        if let remoteError = error as? RemoteCodexCostError,
           remoteError != .unavailable
        {
            remoteError.localizedDescription
        } else {
            Self.hostCheckFailureMessage
        }
    }

    // MARK: Text rendering

    static func renderConfigHostEntry(_ entry: ConfigHostsEntry) -> String {
        let spend: String = if entry.valid {
            entry.costUsage ? "valid, counts toward spend" : "valid, session host only"
        } else {
            "invalid for spend, session host only"
        }
        var line = "\(entry.host): \(spend)"
        if let check = entry.check {
            line += check.ok ? " — check ok" : " — check failed: \(check.error ?? "")"
        }
        return line
    }

    static func renderConfigHostMutation(
        _ result: ConfigHostsMutationResult,
        action: ConfigHostsAction,
        costOnly: Bool) -> String
    {
        var line: String = if !result.changed {
            "Host already \(action == .add ? "configured" : "absent"): \(result.host)"
        } else if action == .add {
            result.costUsage ? "Host added: \(result.host) (cost usage)" : "Host added: \(result.host)"
        } else {
            costOnly ? "Host removed from spend: \(result.host)" : "Host removed: \(result.host)"
        }
        if let check = result.check {
            line += check.ok ? " Check: ok" : " Check: failed — \(check.error ?? "")"
        }
        return line
    }
}

struct ConfigHostsListOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Flag(name: .long("check"), help: "Verify each host over one-shot SSH")
    var check: Bool = false
    @Option(name: .long("defaults-domain"), help: "macOS defaults domain (default: com.steipete.codexbar)")
    var defaultsDomain: String?
}

struct ConfigHostsAddOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Argument(help: "SSH host alias or user@host")
    var host: String = ""
    @Flag(name: .long("cost"), help: "Also count the host toward spend")
    var cost: Bool = false
    @Flag(name: .long("check"), help: "Verify the host over one-shot SSH after the change")
    var check: Bool = false
    @Option(name: .long("defaults-domain"), help: "macOS defaults domain (default: com.steipete.codexbar)")
    var defaultsDomain: String?
}

struct ConfigHostsRemoveOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Argument(help: "SSH host alias or user@host")
    var host: String = ""
    @Flag(name: .long("cost"), help: "Remove only spend tracking, keep the session host")
    var cost: Bool = false
    @Option(name: .long("defaults-domain"), help: "macOS defaults domain (default: com.steipete.codexbar)")
    var defaultsDomain: String?
}

/// A finished host mutation: the next persisted state, whether anything changed, and the
/// stored spelling to report and check.
struct ConfigHostsMutation: Sendable {
    let state: ConfigHostsState
    let changed: Bool
    let host: String
}

struct ConfigHostsState: Equatable, Sendable {
    /// Comma tokens exactly as stored; a write changes only the entries a command addressed.
    var manualTokens: [String] = []
    var costUsageHosts: [String] = []

    /// The sanitized, deduplicated host list the app itself reads from the stored setting.
    var manualHosts: [String] {
        RemoteSessionFetcher.sanitizedHosts(self.manualTokens)
    }

    /// Include rejected Settings tokens in the inventory, preserving the first stored spelling.
    var listedHosts: [String] {
        var seen = Set<String>()
        return self.manualTokens.compactMap { token in
            let host = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, seen.insert(RemoteSessionFetcher.hostIdentityKey(host)).inserted else { return nil }
            return host
        }
    }

    init(manualHosts: [String] = [], costUsageHosts: [String] = []) {
        self.manualTokens = manualHosts
        self.costUsageHosts = costUsageHosts
    }
}

struct ConfigHostsCheckResult: Codable, Equatable, Sendable {
    let ok: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ok, forKey: .ok)
        // Agents read one shape: a missing check stays absent, a present check always names error.
        if let error { try container.encode(error, forKey: .error) } else { try container.encodeNil(forKey: .error) }
    }
}

struct ConfigHostsEntry: Codable, Equatable, Sendable {
    let host: String
    let valid: Bool
    let costUsage: Bool
    var check: ConfigHostsCheckResult?
}

struct ConfigHostsListResult: Encodable, Sendable {
    let hosts: [ConfigHostsEntry]
}

struct ConfigHostsMutationResult: Encodable, Sendable {
    let host: String
    let changed: Bool
    let costUsage: Bool
    var check: ConfigHostsCheckResult?
}
