import Foundation

public struct RemoteSessionHostResult: Equatable, Sendable, Identifiable {
    public let host: String
    public let sessions: [AgentSession]
    public let error: String?

    public var id: String {
        self.host
    }

    public var isReachable: Bool {
        self.error == nil
    }

    public init(host: String, sessions: [AgentSession], error: String?) {
        self.host = host
        self.sessions = sessions
        self.error = error
    }
}

public enum TailscaleStatusParser {
    /// Parses hosts from `tailscale status --json` output.
    ///
    /// Returns `nil` when `data` is not recognizable Tailscale status JSON — a failed, wrong, or
    /// non-Tailscale `tailscale` binary — so callers can fall through to the next candidate. Returns a
    /// possibly-empty list for a valid status that simply has no eligible peers (a real answer, stop).
    package static func parseHosts(from data: Data, excludingLocalHost localHost: String? = nil) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let rawBackendState = root["BackendState"] {
            guard let backendState = rawBackendState as? String,
                  backendState.caseInsensitiveCompare("Running") == .orderedSame
            else { return nil }
        }

        let selfStatus: [String: Any]?
        if let rawSelf = root["Self"] {
            guard let parsedSelf = rawSelf as? [String: Any] else { return nil }
            selfStatus = parsedSelf
        } else {
            selfStatus = nil
        }

        let peers: [[String: Any]]
        let hasPeerShape: Bool
        switch root["Peer"] {
        case let dictionary as [String: [String: Any]]:
            peers = Array(dictionary.values)
            hasPeerShape = true
        case let array as [[String: Any]]:
            peers = array
            hasPeerShape = true
        case is NSNull:
            peers = []
            hasPeerShape = true
        case nil:
            peers = []
            hasPeerShape = false
        default:
            return nil
        }
        guard selfStatus != nil || hasPeerShape else { return nil }
        let localLabels = Set([
            localHost,
            selfStatus?["DNSName"] as? String,
            selfStatus?["HostName"] as? String,
        ].compactMap(self.firstDNSLabel).map { $0.lowercased() })

        var seen = Set<String>()
        return peers.compactMap { peer in
            guard peer["Online"] as? Bool == true,
                  let operatingSystem = peer["OS"] as? String,
                  operatingSystem == "macOS" || operatingSystem == "linux",
                  let label = self.firstDNSLabel(peer["DNSName"] as? String)
            else { return nil }
            let normalized = label.lowercased()
            guard !localLabels.contains(normalized), seen.insert(normalized).inserted else { return nil }
            return label
        }.sorted()
    }

    /// Convenience returning `[]` for unparseable output. Prefer `parseHosts` when the caller needs to
    /// distinguish a failed probe from an empty tailnet.
    public static func hosts(from data: Data, excludingLocalHost localHost: String? = nil) -> [String] {
        self.parseHosts(from: data, excludingLocalHost: localHost) ?? []
    }

    private static func firstDNSLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let label = trimmed.split(separator: ".").first, !label.isEmpty else { return nil }
        return String(label)
    }
}

public struct RemoteSessionFetcher: Sendable {
    public static let bundledCLIFallback = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"

    public init() {}

    public func discoveredHosts(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localHost: String = ProcessInfo.processInfo.hostName) async -> [String]
    {
        let probeEnvironment = Self.tailscaleCLIEnvironment(from: environment)
        let candidates = Self.tailscaleBinaryCandidates(path: environment["PATH"])
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        return await Self.firstDiscoveredHosts(candidates: candidates, localHost: localHost) { binary in
            guard let result = try? await SubprocessRunner.run(
                binary: binary,
                arguments: ["status", "--json"],
                environment: probeEnvironment,
                timeout: 5,
                label: "Tailscale session host discovery")
            else { return nil }
            return Data(result.stdout.utf8)
        }
    }

    /// Runs `tailscale status --json` on each candidate in order, falling through to the next when a
    /// candidate fails (`run` returns nil), returns invalid status JSON, or reports an inactive backend.
    /// Returns the first candidate's parsed hosts (possibly empty), or `[]` if none succeed. This keeps
    /// the app-binary fallback working even when an earlier — but non-functional — `tailscale` variant
    /// is installed (e.g. an open-source/Homebrew CLI that isn't the active client).
    package static func firstDiscoveredHosts(
        candidates: [String],
        localHost: String?,
        run: (String) async -> Data?) async -> [String]
    {
        for binary in candidates {
            guard let data = await run(binary),
                  let hosts = TailscaleStatusParser.parseHosts(from: data, excludingLocalHost: localHost)
            else { continue }
            return hosts
        }
        return []
    }

    public func fetch(
        hosts: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> [RemoteSessionHostResult]
    {
        let normalizedHosts = Self.sanitizedHosts(hosts)
        return await withTaskGroup(
            of: RemoteSessionHostResult.self,
            returning: [RemoteSessionHostResult].self)
        { group in
            for host in normalizedHosts {
                group.addTask {
                    await self.fetch(host: host, environment: environment)
                }
            }
            var results: [RemoteSessionHostResult] = []
            for await result in group {
                results.append(result)
            }
            return results
                .sorted { lhs, rhs in lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending }
        }
    }

    public func focus(
        sessionID: String,
        host: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async
    {
        guard let host = Self.sanitizedHosts([host]).first else { return }
        guard let ssh = self.findExecutable("ssh", environment: environment) ??
            (["/usr/bin/ssh", "/bin/ssh"].first { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let command = "codexbar sessions focus \(Self.shellQuote(sessionID)) || " +
            "\(Self.shellQuote(Self.bundledCLIFallback)) sessions focus \(Self.shellQuote(sessionID))"
        _ = try? await SubprocessRunner.run(
            binary: ssh,
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", host, "sh", "-lc", Self.shellQuote(command)],
            environment: environment,
            timeout: 5,
            acceptsNonZeroExit: true,
            label: "focus remote agent session")
    }

    private func fetch(host: String, environment: [String: String]) async -> RemoteSessionHostResult {
        guard let ssh = self.findExecutable("ssh", environment: environment) ??
            (["/usr/bin/ssh", "/bin/ssh"].first { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            return RemoteSessionHostResult(host: host, sessions: [], error: "ssh not found")
        }
        let command = "codexbar sessions --json || " +
            "\(Self.shellQuote(Self.bundledCLIFallback)) sessions --json"
        do {
            let result = try await SubprocessRunner.run(
                binary: ssh,
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=3",
                    host,
                    "sh", "-lc", Self.shellQuote(command),
                ],
                environment: environment,
                timeout: 5,
                label: "fetch remote agent sessions")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var sessions = try decoder.decode([AgentSession].self, from: Data(result.stdout.utf8))
            for index in sessions.indices {
                sessions[index].host = host
            }
            return RemoteSessionHostResult(host: host, sessions: sessions, error: nil)
        } catch {
            return RemoteSessionHostResult(host: host, sessions: [], error: error.localizedDescription)
        }
    }

    /// Ordered candidate paths for the `tailscale` CLI, most-preferred first.
    ///
    /// The macOS app ships its CLI as a thin `/bin/sh` wrapper (usually
    /// `/usr/local/bin/tailscale`) around the app's dual-mode binary. We prefer the
    /// wrapper, but a GUI-launched CodexBar inherits a minimal `PATH` (`/usr/bin:/bin`)
    /// that omits the standard CLI locations, so we also probe them explicitly before
    /// falling back to the app binary itself.
    package static func tailscaleBinaryCandidates(path: String?) -> [String] {
        let pathDirs = path?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        var candidates = (pathDirs + ["/usr/local/bin", "/opt/homebrew/bin"])
            .filter { seen.insert($0).inserted }
            .map { $0 + "/tailscale" }
        // Last resort: the dual-mode app binary. Must be run via
        // `tailscaleCLIEnvironment(from:)` so it stays in CLI mode.
        candidates.append("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        return candidates
    }

    /// Environment that keeps the dual-mode Tailscale app binary in CLI mode.
    ///
    /// With no shell/terminal marker present the binary boots the full menu-bar GUI
    /// (SkyLight/WindowServer, status icon) instead of running the CLI: it never emits
    /// JSON, the probe times out, and the Tailscale icon flickers on every refresh. A
    /// set `TERM` or `SHLVL` forces CLI mode (argv[0] casing and `XPC_SERVICE_NAME` do
    /// not). `SHLVL` is what the app's own `/bin/sh` CLI wrapper injects, so we mirror it here.
    ///
    /// Applied to every probe, not just the app-binary fallback: it is redundant but harmless for the
    /// CLI wrapper (itself a `/bin/sh` script that already exports `SHLVL`), and injecting it
    /// unconditionally keeps CLI mode guaranteed regardless of which binary `tailscaleBinary` resolves.
    /// An existing `TERM`/`SHLVL` (real terminal context) is left untouched.
    package static func tailscaleCLIEnvironment(from environment: [String: String]) -> [String: String] {
        guard environment["TERM"] == nil, environment["SHLVL"] == nil else { return environment }
        var environment = environment
        environment["SHLVL"] = "1"
        return environment
    }

    private func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":")
            .map { String($0) + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func sanitizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.compactMap { rawHost in
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUnsafeScalar = host.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) ||
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            guard !host.isEmpty,
                  !host.hasPrefix("-"),
                  !hasUnsafeScalar,
                  seen.insert(host.lowercased()).inserted
            else { return nil }
            return host
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
