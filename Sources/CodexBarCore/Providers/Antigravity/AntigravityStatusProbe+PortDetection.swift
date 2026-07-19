import Foundation

/// Parses Linux `/proc/<pid>/net/tcp{,6}` output to recover the listening ports
/// owned by a process. The parsing is platform-independent for focused tests.
enum ProcNetTCPListeningPortParser {
    /// The `st` column value for a socket in the LISTEN state.
    private static let listenState = "0A"

    /// Extracts the socket inode from a `/proc/<pid>/fd` symlink destination such
    /// as `socket:[12345]`. Returns nil for non-socket descriptors.
    static func socketInode(fromLink destination: String) -> String? {
        let prefix = "socket:["
        guard destination.hasPrefix(prefix), destination.hasSuffix("]") else { return nil }
        let inode = destination.dropFirst(prefix.count).dropLast()
        return inode.isEmpty ? nil : String(inode)
    }

    /// Returns the local ports of LISTEN sockets whose inode is in `socketInodes`.
    ///
    /// `content` is the raw text of a process-scoped `tcp` or `tcp6` table. Each
    /// row encodes the local endpoint as `ADDRESS:PORT` (for example,
    /// `0100007F:1F90` uses port 8080) and the owning socket inode in column ten.
    static func listeningPorts(_ content: String, socketInodes: Set<String>) -> Set<Int> {
        var ports: Set<Int> = []
        for line in content.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            // Columns: sl local_address rem_address st ... uid timeout inode
            guard columns.count > 9,
                  columns[3] == self.listenState,
                  socketInodes.contains(String(columns[9]))
            else { continue }
            let localAddress = columns[1]
            guard let separator = localAddress.lastIndex(of: ":"),
                  let port = Int(localAddress[localAddress.index(after: separator)...], radix: 16),
                  (0...Int(UInt16.max)).contains(port)
            else { continue }
            ports.insert(port)
        }
        return ports
    }
}

extension AntigravityStatusProbe {
    /// Resolves the TCP ports the process `pid` is listening on. Uses `lsof` when
    /// present (the common denominator across macOS and Linux) and falls back to
    /// the kernel's `/proc` interface on Linux hosts without `lsof`.
    static func listeningPorts(pid: Int, timeout: TimeInterval) async throws -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })

        if let lsof {
            return try await Self.lsofListeningPorts(lsof: lsof, pid: pid, timeout: timeout)
        }

        #if os(Linux)
        // `lsof` is frequently absent on minimal Linux hosts. Fall back to the
        // kernel's /proc interface, mirroring the /proc/<pid>/cwd fallback that
        // LocalAgentSessionScanner.cwdByPID already uses when lsof is missing.
        let ports = Self.procListeningPorts(pid: pid)
        if ports.isEmpty {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        return ports
        #else
        throw AntigravityStatusProbeError.portDetectionFailed("lsof not available")
        #endif
    }

    private static func lsofListeningPorts(
        lsof: String,
        pid: Int,
        timeout: TimeInterval) async throws -> [Int]
    {
        let env = ProcessInfo.processInfo.environment
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                binary: lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
                environment: env,
                timeout: timeout,
                label: "antigravity-lsof")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr)
            where code == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        let ports = Self.parseListeningPorts(result.stdout)
        if ports.isEmpty {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        return ports
    }

    private static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: output),
                  let value = Int(output[range]) else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    /// Recovers the listening ports owned by `pid` by matching its open socket
    /// inodes against the TCP tables from the same process/network namespace.
    static func procListeningPorts(pid: Int, procRoot: String = "/proc") -> [Int] {
        let processRoot = "\(procRoot)/\(pid)"
        let inodes = Self.socketInodes(processRoot: processRoot)
        guard !inodes.isEmpty else { return [] }
        var ports: Set<Int> = []
        for path in ["\(processRoot)/net/tcp", "\(processRoot)/net/tcp6"] {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            ports.formUnion(ProcNetTCPListeningPortParser.listeningPorts(content, socketInodes: inodes))
        }
        return ports.sorted()
    }

    /// Collects the socket inodes referenced by the process's open descriptors.
    private static func socketInodes(processRoot: String) -> Set<String> {
        let fdDirectory = "\(processRoot)/fd"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: fdDirectory) else { return [] }
        var inodes: Set<String> = []
        for entry in entries {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: "\(fdDirectory)/\(entry)"),
                let inode = ProcNetTCPListeningPortParser.socketInode(fromLink: destination)
            else { continue }
            inodes.insert(inode)
        }
        return inodes
    }
}
