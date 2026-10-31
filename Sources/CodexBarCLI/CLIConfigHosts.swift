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
            // Pick up values the running app may have written moments ago.
            defaults.synchronize()
            let state = try Self.configHostsState(in: defaults)
            var next = state
            var changed = false
            var host = ""
            if action != .list {
                guard let argument = values.positional.first, !argument.isEmpty else {
                    throw PreferencesDocument.Error.invalid("\(action) requires one <host> argument")
                }
                let mutation = action == .add
                    ? try Self.addedConfigHost(argument, to: state, cost: values.flags.contains("cost"))
                    : try Self.removedConfigHost(argument, from: state, costOnly: values.flags.contains("cost"))
                next = mutation.state
                changed = mutation.changed
                // Report and check the host as it is stored, never the raw argument.
                host = mutation.host
                if changed {
                    try Self.queueConfigHosts(next, in: defaults)
                    if domain == PreferencesDocument.defaultsDomain {
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name(PreferencesDocument.importNotification),
                            object: nil,
                            userInfo: nil,
                            deliverImmediately: true)
                    }
                }
            }
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
                    costUsage: next.costUsageHosts.contains { Self.configHostKey($0) == Self.configHostKey(host) },
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

    /// One Ctrl-C must cancel the check and reap SSH children, like the cost report.
    private static func runHostsCheck(_ hosts: [String]) async throws -> [ConfigHostsCheckResult] {
        try await CLICodexHostsTerminationCleanup.run { try await Self.checkConfigHosts(hosts) }
    }

    // MARK: Pure host-list logic

    /// Hosts as the app resolves them: persisted values overridden by any queued CLI import,
    /// with the app's load-time spend filter applied.
    static func configHostsState(in defaults: UserDefaults) throws -> ConfigHostsState {
        var manualRaw = defaults.string(forKey: "agentSessionsManualHosts") ?? ""
        var costRaw = defaults.stringArray(forKey: "costUsageHosts") ?? []
        if let pending = try defaults.data(forKey: PreferencesDocument.pendingImportKey)
            .map({ try PreferencesDocument(data: $0) })
        {
            // Hosts are deliberately outside the portable export allowlist; a queued import
            // still carries them, and it is newer than the persisted values.
            if let value: String = try pending.value("agentSessionsManualHosts") { manualRaw = value }
            if let value: [String] = try pending.value("costUsageHosts") { costRaw = value }
        }
        let manualHosts = RemoteSessionFetcher.sanitizedHosts(manualRaw.components(separatedBy: ","))
        return ConfigHostsState(
            manualHosts: manualHosts,
            // Mirror of the app's load: spend hosts are valid manual hosts the user selected.
            costUsageHosts: RemoteCodexCostFetcher.costUsageCandidates(in: manualHosts)
                .filter { candidate in costRaw.contains { Self.configHostKey($0) == Self.configHostKey(candidate) } })
    }

    /// The identity `RemoteSessionFetcher.sanitizedHosts` deduplicates on: case-insensitive
    /// host part, case-sensitive SSH username.
    static func configHostKey(_ host: String) -> String {
        guard let separator = host.lastIndex(of: "@") else { return host.lowercased() }
        return String(host[...separator]) + host[host.index(after: separator)...].lowercased()
    }

    static func configHostsEntries(_ state: ConfigHostsState) -> [ConfigHostsEntry] {
        state.manualHosts.map { host in
            ConfigHostsEntry(
                host: host,
                valid: (try? RemoteCodexCostFetcher.validateHost(host)) != nil,
                costUsage: state.costUsageHosts.contains { Self.configHostKey($0) == Self.configHostKey(host) },
                check: nil)
        }
    }

    static func addedConfigHost(
        _ rawHost: String,
        to state: ConfigHostsState,
        cost: Bool)
        throws -> (state: ConfigHostsState, changed: Bool, host: String)
    {
        guard let host = RemoteSessionFetcher.sanitizedHosts([rawHost]).first else {
            throw PreferencesDocument.Error.invalid(RemoteCodexCostError.invalidHost.localizedDescription)
        }
        try RemoteCodexCostFetcher.validateHost(host)
        var next = state
        var changed = false
        // Keep the stored spelling; `devbox` and a stored `DevBox` are one host.
        let canonical: String
        if let existing = next.manualHosts.first(where: { Self.configHostKey($0) == Self.configHostKey(host) }) {
            canonical = existing
        } else {
            canonical = host
            next.manualHosts.append(host)
            changed = true
        }
        if cost {
            // The spend list stays a subset of valid manual hosts, as the app's setter enforces.
            let candidates = Set(RemoteCodexCostFetcher.costUsageCandidates(in: next.manualHosts)
                .map(Self.configHostKey))
            var spend = next.costUsageHosts.filter { candidates.contains(Self.configHostKey($0)) }
            if !spend.contains(where: { Self.configHostKey($0) == Self.configHostKey(canonical) }) {
                spend.append(canonical)
                changed = true
            }
            next.costUsageHosts = spend
        }
        return (next, changed, canonical)
    }

    static func removedConfigHost(
        _ rawHost: String,
        from state: ConfigHostsState,
        costOnly: Bool)
        throws -> (state: ConfigHostsState, changed: Bool, host: String)
    {
        guard let host = RemoteSessionFetcher.sanitizedHosts([rawHost]).first else {
            throw PreferencesDocument.Error.invalid(RemoteCodexCostError.invalidHost.localizedDescription)
        }
        var next = state
        var changed = false
        let spend = next.costUsageHosts
        let canonical = next.manualHosts.first { Self.configHostKey($0) == Self.configHostKey(host) } ?? host
        if costOnly {
            next.costUsageHosts = spend.filter { Self.configHostKey($0) != Self.configHostKey(host) }
            changed = spend != next.costUsageHosts
        } else {
            // Removal may address hosts Settings typed without strict validation.
            let manual = next.manualHosts
            next.manualHosts = manual.filter { Self.configHostKey($0) != Self.configHostKey(host) }
            changed = manual != next.manualHosts
            let candidates = Set(RemoteCodexCostFetcher.costUsageCandidates(in: next.manualHosts)
                .map(Self.configHostKey))
            next.costUsageHosts = spend.filter { candidates.contains(Self.configHostKey($0)) }
            changed = changed || spend != next.costUsageHosts
        }
        return (next, changed, canonical)
    }

    static func queueConfigHosts(_ state: ConfigHostsState, in defaults: UserDefaults) throws {
        var document = PreferencesDocument()
        try document.set("agentSessionsManualHosts", state.manualHosts.joined(separator: ","))
        try document.set("costUsageHosts", state.costUsageHosts)
        try document.queueImport(in: defaults)
    }

    // MARK: Host check

    static let hostCheckFailureMessage =
        "Could not check the host over SSH. Verify noninteractive SSH access and a trusted host key."

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
        return try await withThrowingTaskGroup(of: (Int, ConfigHostsCheckResult).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    do {
                        try await resolvedFetch(host)
                        return (index, ConfigHostsCheckResult(ok: true, error: nil))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        return (index, ConfigHostsCheckResult(ok: false, error: Self.hostCheckError(error)))
                    }
                }
            }
            var indexed: [(Int, ConfigHostsCheckResult)] = []
            for try await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Keep the named cause: an invalid host and an outdated remote CLI stay distinguishable.
    static func hostCheckError(_ error: Error) -> String {
        if let remoteError = error as? RemoteCodexCostError {
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

/// Shared Ctrl-C cleanup for one-shot SSH collections; the cost report and the host check
/// use the same monitor/bind/cancel/reraise lifecycle.
enum CLICodexHostsTerminationCleanup {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { cancellation.request(signal: $0) }
        let task = Task { try await operation() }
        cancellation.bind { task.cancel() }
        let result = await task.result
        monitor.cancel()
        if let signal = cancellation.signal {
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signal)
        }
        return try result.get()
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

struct ConfigHostsState: Equatable, Sendable {
    var manualHosts: [String] = []
    var costUsageHosts: [String] = []
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
