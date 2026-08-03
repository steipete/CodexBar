import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#endif

struct DarwinProcessEnumeratorTests {
    @Test
    func `proc args parser joins normal argv`() {
        let data = Self.procArgsData(arguments: ["/usr/bin/tool", "--flag", "value"])

        #expect(DarwinProcessEnumerator.parseProcArgs2(data) == "/usr/bin/tool --flag value")
    }

    @Test
    func `proc args parser accepts zero argc`() {
        let data = Self.procArgsData(arguments: [])

        #expect(DarwinProcessEnumerator.parseProcArgs2(data)?.isEmpty == true)
    }

    @Test
    func `proc args parser rejects truncated buffer`() {
        #expect(DarwinProcessEnumerator.parseProcArgs2(Data([2, 0, 0])) == nil)
    }

    @Test
    func `proc args parser excludes environment`() {
        let data = Self.procArgsData(
            arguments: ["/usr/bin/tool", "--flag"],
            environment: ["SECRET=value", "HOME=/tmp"])

        let command = DarwinProcessEnumerator.parseProcArgs2(data)
        #expect(command == "/usr/bin/tool --flag")
        #expect(command?.contains("SECRET") == false)
        #expect(command?.contains("HOME") == false)
    }

    @Test
    func `proc args parser preserves embedded empty arguments`() {
        let data = Self.procArgsData(arguments: ["/usr/bin/tool", "", "value"])

        #expect(DarwinProcessEnumerator.parseProcArgs2(data) == "/usr/bin/tool  value")
    }

    @Test
    func `proc args parser rejects argc larger than available strings`() {
        var data = Self.procArgsData(arguments: ["/usr/bin/tool", "value"])
        data.replaceSubrange(0..<4, with: Self.littleEndianBytes(3))

        #expect(DarwinProcessEnumerator.parseProcArgs2(data) == nil)
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
