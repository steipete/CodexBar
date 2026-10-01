import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#endif

struct DarwinProcessEnumeratorTests {
    @Test
    func `proc args parser preserves normal argv`() {
        let data = Self.procArgsData(arguments: ["/usr/bin/tool", "--flag", "value"])

        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data) == ["/usr/bin/tool", "--flag", "value"])
    }

    @Test
    func `proc args parser accepts zero argc`() {
        let data = Self.procArgsData(arguments: [])

        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data) == [])
    }

    @Test
    func `proc args parser rejects truncated buffer`() {
        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(Data([2, 0, 0])) == nil)
    }

    @Test
    func `proc args parser excludes environment`() {
        let data = Self.procArgsData(
            arguments: ["/usr/bin/tool", "--flag"],
            environment: ["SECRET=value", "HOME=/tmp"])

        let command = DarwinProcessEnumerator.parseProcArgs2Arguments(data)?.joined(separator: " ")
        #expect(command == "/usr/bin/tool --flag")
        #expect(command?.contains("SECRET") == false)
        #expect(command?.contains("HOME") == false)
    }

    @Test
    func `proc args selector environment accepts normal terminators and padding`() {
        var data = Self.procArgsData(
            arguments: ["/usr/local/bin/omp", "", "--profile", "work"],
            environment: ["HOME=/synthetic/home", "OMP_PROFILE=work", "UNRELATED=value"])
        data.append(contentsOf: [0, 0, 0])

        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data) == [
            "/usr/local/bin/omp", "", "--profile", "work",
        ])
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(data) == [
            "HOME": "/synthetic/home", "OMP_PROFILE": "work",
        ])
        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data)?.contains("HOME=/synthetic/home") == false)
    }

    @Test
    func `proc args selector environment distinguishes omitted empty and truncated evidence`() {
        let empty = Self.procArgsData(arguments: ["pi"])
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(empty) == nil)
        var paddedEmpty = empty
        paddedEmpty.append(contentsOf: [0, 0])
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(paddedEmpty) == nil)
        let knownEmpty = Self.procArgsData(arguments: ["pi"], environment: ["UNRELATED=value"])
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(knownEmpty) == [:])
        var truncated = Self.procArgsData(arguments: ["pi"], environment: ["HOME=/synthetic/home"])
        truncated.removeLast()
        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(truncated) == ["pi"])
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(truncated) == nil)
    }

    @Test
    func `proc args selector environment stops before Apple vectors`() {
        var data = Self.procArgsData(arguments: ["pi"], environment: ["HOME=/synthetic/process"])
        data.append(0)
        data.append(contentsOf: "HOME=/synthetic/apple-vector\0ptr_munge=ignored\0".utf8)
        #expect(DarwinProcessEnumerator.parseProcArgs2Environment(data) == [
            "HOME": "/synthetic/process",
        ])
    }

    @Test
    func `proc args parser preserves embedded empty arguments`() {
        let data = Self.procArgsData(arguments: ["/usr/bin/tool", "", "value"])

        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data) == ["/usr/bin/tool", "", "value"])
    }

    @Test
    func `proc args parser rejects argc larger than available strings`() {
        var data = Self.procArgsData(arguments: ["/usr/bin/tool", "value"])
        data.replaceSubrange(0..<4, with: Self.littleEndianBytes(3))

        #expect(DarwinProcessEnumerator.parseProcArgs2Arguments(data) == nil)
    }

    @Test
    func `antigravity candidate paths cover known executable shapes`() {
        let paths = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm",
            "/opt/editor/extensions/antigravity/bin/language_server",
            "/usr/local/bin/agy",
            "~/.antigravity/x/antigravity-cli",
            "language_server",
        ]

        for path in paths {
            #expect(DarwinProcessEnumerator.isAntigravityCandidatePath(path))
        }
    }

    @Test
    func `antigravity candidate paths reject unrelated executables`() {
        let paths = [
            "/bin/ps",
            "/Applications/Xcode.app/Contents/MacOS/Xcode",
            "/opt/gravity/bin/tool",
        ]

        for path in paths {
            #expect(!DarwinProcessEnumerator.isAntigravityCandidatePath(path))
        }
    }

    @Test
    func `antigravity candidate prefilter is a superset of classifier fixtures`() {
        let fixtures = [
            (
                "/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token token",
                "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            (
                "/Applications/Google Antigravity.app/Contents/Resources/bin/language-server --csrf_token token",
                "/Applications/Google Antigravity.app/Contents/Resources/bin/language-server"),
            (
                "/Users/test/.local/bin/agy -p hello",
                "/Users/test/.local/bin/agy"),
            (
                "node /Users/test/.gemini/antigravity-cli/build/mcp-server.cjs --app_data_dir antigravity",
                "node"),
        ]

        for fixture in fixtures {
            #expect(AntigravityStatusProbe.antigravityProcessKind(fixture.0) != nil)
            #expect(DarwinProcessEnumerator.isAntigravityCandidatePath(fixture.1))
        }
    }

    #if canImport(Darwin)
    @Test
    func `self executable path is absolute and nonempty`() throws {
        let path = try #require(DarwinProcessEnumerator.executablePath(pid: getpid()))

        #expect(path.hasPrefix("/"))
        #expect(!URL(fileURLWithPath: path).lastPathComponent.isEmpty)
    }

    @Test
    func `self command line contains executable basename`() throws {
        let path = try #require(DarwinProcessEnumerator.executablePath(pid: getpid()))
        let command = try #require(DarwinProcessEnumerator.commandLine(pid: getpid()))

        #expect(command.contains(URL(fileURLWithPath: path).lastPathComponent))
    }

    @Test
    func `self bsd info reports parent and plausible start time`() throws {
        let info = try #require(DarwinProcessEnumerator.bsdInfo(pid: getpid()))
        let now = Date()

        #expect(info.ppid == getppid())
        #expect(info.startTime <= now)
        #expect(info.startTime > Date.distantPast)
    }

    @Test
    func `self current working directory matches file manager`() throws {
        let currentDirectory = try #require(DarwinProcessEnumerator.currentWorkingDirectory(pid: getpid()))
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let actual = URL(fileURLWithPath: currentDirectory).standardizedFileURL.path

        #expect(actual == expected)
    }

    @Test
    func `self listening tcp ports include an open loopback listener`() throws {
        let listener = try Self.openLoopbackListener()
        defer { close(listener.fileDescriptor) }

        #expect(DarwinProcessEnumerator.listeningTCPPorts(pid: getpid()).contains(listener.port))
    }

    @Test
    func `darwin process record keeps agent argv when the executable was deleted`() throws {
        // proc_pidpath returns ENOENT after an updater removes the package directory of a running binary.
        let record = try #require(LocalAgentSessionScanner.darwinProcessRecord(
            pid: 4242,
            bsdInfo: { _ in (ppid: 1, startTime: Date(timeIntervalSince1970: 1_700_000_000)) },
            processArguments: { _ in (arguments: ["claude"], piSelectorEnvironment: nil) },
            executablePath: { _ in nil }))

        #expect(record.command == "claude")
        #expect(record.arguments == ["claude"])
        #expect(AgentPSOutputParser.provider(for: record) == .claude)
        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [4242])
    }

    @Test
    func `running agent remains discoverable after its executable is unlinked`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        try Data(contentsOf: URL(fileURLWithPath: "/bin/cat")).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        // Relocated platform binaries need a new signature; ad-hoc signing never accesses a signing key.
        _ = try await SubprocessRunner.run(
            binary: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", executable.path],
            environment: [:],
            timeout: 10,
            label: "synthetic-agent-signing")
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.environment = [:]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let ready = Data("ready\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: ready)
        #expect(try output.fileHandleForReading.read(upToCount: ready.count) == ready)
        let pid = process.processIdentifier
        #expect(DarwinProcessEnumerator.executablePath(pid: pid) != nil)
        try FileManager.default.removeItem(at: executable)
        #expect(DarwinProcessEnumerator.executablePath(pid: pid) == nil)
        let record = try #require(LocalAgentSessionScanner.darwinProcessRecord(pid: pid))
        #expect(AgentPSOutputParser.agentProcesses(from: [record]).map(\.pid) == [pid])
        #expect(AgentPSOutputParser.provider(for: record) == .claude)
    }

    @Test
    func `deleted executable cannot establish trusted chatgpt app server identity`() {
        #expect(!ChatGPTCodexProcessTrust.isTrusted(
            4242,
            executablePath: { _ in nil },
            processIsTrusted: { _ in
                Issue.record("Missing executable path must fail before signature validation")
                return true
            },
            appIsTrusted: { _ in true }))
    }

    @Test
    func `darwin process record falls back to the executable path without argv`() throws {
        let record = try #require(LocalAgentSessionScanner.darwinProcessRecord(
            pid: 4243,
            bsdInfo: { _ in (ppid: 1, startTime: Date(timeIntervalSince1970: 1_700_000_000)) },
            processArguments: { _ in nil },
            executablePath: { _ in "/opt/homebrew/bin/codex" }))

        #expect(record.command == "/opt/homebrew/bin/codex")
        #expect(record.arguments == nil)
    }

    @Test
    func `darwin process record skips processes without argv or executable path`() {
        let record = LocalAgentSessionScanner.darwinProcessRecord(
            pid: 4244,
            bsdInfo: { _ in (ppid: 1, startTime: Date(timeIntervalSince1970: 1_700_000_000)) },
            processArguments: { _ in nil },
            executablePath: { _ in nil })

        #expect(record == nil)
    }
    #endif

    private static func procArgsData(arguments: [String], environment: [String] = []) -> Data {
        var data = Data(self.littleEndianBytes(Int32(arguments.count)))
        data.append(contentsOf: "/usr/bin/exec".utf8)
        data.append(0)
        data.append(contentsOf: [0, 0])
        for value in arguments + environment {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data
    }

    private static func littleEndianBytes(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    #if canImport(Darwin)
    private static func openLoopbackListener() throws -> (fileDescriptor: Int32, port: Int) {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fileDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }

            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    getsockname(fileDescriptor, socketAddress, &addressLength)
                }
            }
            guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return (fileDescriptor, Int(UInt16(bigEndian: address.sin_port)))
        } catch {
            close(fileDescriptor)
            throw error
        }
    }
    #endif
}
