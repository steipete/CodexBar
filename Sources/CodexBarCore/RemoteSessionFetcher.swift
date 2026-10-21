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
        let candidates = Self.tailscaleBinaryCandidates(path: environment["PATH"])
        return await Self.firstDiscoveredHosts(candidates: candidates, localHost: localHost) { binary in
            guard let result = try? await SubprocessRunner.run(
                binary: binary,
                arguments: ["status", "--json"],
                environment: environment,
                timeout: 5,
                label: "Tailscale session host discovery")
            else { return nil }
            return Data(result.stdout.utf8)
        }
    }

    /// Probe only standalone CLIs: app launchers can start a disconnected VPN even for status.
    package static func firstDiscoveredHosts(
        candidates: [String],
        localHost: String?,
        isStandaloneCLI: (String) -> Bool = Self.isStandaloneTailscaleCLI,
        run: (String) async -> Data?) async -> [String]
    {
        for binary in candidates where isStandaloneCLI(binary) {
            guard let data = await run(binary),
                  let hosts = TailscaleStatusParser.parseHosts(from: data, excludingLocalHost: localHost)
            else { continue }
            return hosts
        }
        CodexBarLog.logger("sessions").debug(
            "No active standalone Tailscale CLI found; app bundles and launcher scripts are skipped.")
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
        let command = Self.remoteSessionsCommand()
        do {
            let result = try await SubprocessRunner.run(
                binary: ssh,
                arguments: [
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "ConnectTimeout=3",
                    host,
                    "sh",
                    "-lc",
                    Self.shellQuote(command),
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

    /// Tries the v2 session JSON protocol first, then the legacy v1 form, for both PATH and the
    /// bundled app CLI. Each fallback is reached only when the preceding command exits non-zero.
    package static func remoteSessionsCommand() -> String {
        let bundledCLI = Self.shellQuote(Self.bundledCLIFallback)
        return [
            "codexbar sessions --json-v2",
            "codexbar sessions --json",
            "\(bundledCLI) sessions --json-v2",
            "\(bundledCLI) sessions --json",
        ].joined(separator: " || ")
    }

    /// PATH first, then standalone CLI installation directories omitted by GUI launch environments.
    package static func tailscaleBinaryCandidates(path: String?) -> [String] {
        let pathDirs = PathBuilder.searchDirectories(path?.split(separator: ":").map(String.init) ?? [])
        var seen = Set<String>()
        return (pathDirs + ["/usr/local/bin", "/opt/homebrew/bin"])
            .filter { seen.insert($0).inserted }
            .map { $0 + "/tailscale" }
    }

    package static func isStandaloneTailscaleCLI(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !url.path.lowercased().contains(".app/"),
              FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              let file = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Mach-O (including universal binaries) or ELF, never a wrapper that could launch the app.
        return [
            0xFEED_FACE,
            0xCEFA_EDFE,
            0xFEED_FACF,
            0xCFFA_EDFE,
            0xCAFE_BABE,
            0xBEBA_FECA,
            0xCAFE_BABF,
            0xBFBA_FECA,
            0x7F45_4C46,
        ].contains(magic)
    }

    private func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return BinaryLocator.find(name, in: path.split(separator: ":").map(String.init), fileManager: .default)
    }

    public static func sanitizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.compactMap { rawHost in
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUnsafeScalar = host.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) ||
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            let key: String = if let separator = host.lastIndex(of: "@") {
                String(host[...separator]) + host[host.index(after: separator)...].lowercased()
            } else {
                host.lowercased()
            }
            guard !host.isEmpty,
                  !host.hasPrefix("-"),
                  !hasUnsafeScalar,
                  seen.insert(key).inserted
            else { return nil }
            return host
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
