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
    public static func hosts(from data: Data, excludingLocalHost localHost: String? = nil) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers: [[String: Any]] = if let dictionary = root["Peer"] as? [String: [String: Any]] {
            Array(dictionary.values)
        } else if let array = root["Peer"] as? [[String: Any]] {
            array
        } else {
            []
        }
        let selfStatus = root["Self"] as? [String: Any]
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
        guard let tailscale = self.tailscaleBinary(environment: environment),
              let result = try? await SubprocessRunner.run(
                  binary: tailscale,
                  arguments: ["status", "--json"],
                  environment: environment,
                  timeout: 5,
                  label: "Tailscale session host discovery"),
              let data = result.stdout.data(using: .utf8)
        else { return [] }
        return TailscaleStatusParser.hosts(from: data, excludingLocalHost: localHost)
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

    private func tailscaleBinary(environment: [String: String]) -> String? {
        self.findExecutable("tailscale", environment: environment) ?? {
            let bundled = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
            return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil
        }()
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
