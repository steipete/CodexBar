import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexLocalProfileManagerTests {
    @Test
    func `save current profile copies live auth into profiles directory`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let runtime = TestCodexLocalProfileRuntime()
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        let result = try await manager.saveCurrentProfile(named: "plus-a")

        let profileURL = root.appendingPathComponent("profiles/plus-a.json")
        #expect(result.profile.alias == "plus-a")
        #expect(FileManager.default.fileExists(atPath: profileURL.path))
        #expect(try Data(contentsOf: profileURL) == Data(contentsOf: authURL))
    }

    @Test
    func `save current profile rejects invalid names`() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try? self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.invalidProfileName) {
            try await manager.saveCurrentProfile(named: "plus a")
        }
    }

    @Test
    func `save current profile rejects reserved synthetic names`() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try? self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.invalidProfileName) {
            try await manager.saveCurrentProfile(named: "Live")
        }
        await #expect(throws: CodexLocalProfileManagerError.invalidProfileName) {
            try await manager.saveCurrentProfile(named: "Current")
        }
    }

    @Test
    func `save current profile rejects duplicate names`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-a.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.duplicateProfileName("plus-a")) {
            try await manager.saveCurrentProfile(named: "plus-a")
        }
    }

    @Test
    func `save current profile requires valid live auth`() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.authFileMissing(authURL.path)) {
            try await manager.saveCurrentProfile(named: "plus-a")
        }
    }

    @Test
    func `save current profile reports running processes without confirmation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let runtime = TestCodexLocalProfileRuntime(
            runningProcesses: CodexLocalProfileRunningProcesses(
                codexAppRunning: true,
                cliProcesses: [.init(id: 42, command: "codex")]))
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.runningProcessesFound(runtime.runningProcessesStub)) {
            try await manager.saveCurrentProfile(named: "plus-a")
        }
        #expect(runtime.closeCallCount == 0)
    }

    @Test
    func `save current profile rejects symlinked auth file`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realAuthURL = root.appendingPathComponent("real-auth.json")
        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: realAuthURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try FileManager.default.createSymbolicLink(at: authURL, withDestinationURL: realAuthURL)
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.symlinkNotAllowed(authURL.path)) {
            try await manager.saveCurrentProfile(named: "plus-a")
        }
    }

    @Test
    func `save current profile hardens directory and file permissions`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        _ = try await manager.saveCurrentProfile(named: "plus-a")

        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("plus-a.json")
        #expect(try self.posixPermissions(at: profilesURL) == 0o700)
        #expect(try self.posixPermissions(at: profileURL) == 0o600)
    }

    @Test
    func `save rejects stale confirmed running process approval`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let runtime = TestCodexLocalProfileRuntime(
            runningProcesses: CodexLocalProfileRunningProcesses(
                codexAppRunning: false,
                cliProcesses: [.init(id: 101, command: "codex chat")]))
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))
        let staleApproval = CodexLocalProfileRunningProcesses(
            codexAppRunning: true,
            cliProcesses: [.init(id: 99, command: "codex login")])

        await #expect(throws: CodexLocalProfileManagerError.runningProcessesFound(runtime.runningProcessesStub)) {
            try await manager.saveCurrentProfile(named: "plus-a", confirmedProcesses: staleApproval)
        }
        #expect(runtime.closeCallCount == 0)
    }

    @Test
    func `switch creates backup replaces live auth and reopens app`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let runtime = TestCodexLocalProfileRuntime()
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        let result = try await manager.switchToProfile(at: profileURL.path)

        #expect(try Data(contentsOf: authURL) == Data(contentsOf: profileURL))
        let backupURL = try #require(result.backupURL)
        #expect(backupURL.lastPathComponent.hasPrefix("auth-"))
        #expect(backupURL.pathExtension == "json")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(result.profile.alias == "plus-b")
        #expect(runtime.reopenCallCount == 1)
        #expect(result.reopenError == nil)
    }

    @Test
    func `switch leaves live auth unchanged when source profile is invalid`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try Data("{\"broken\":true}".utf8).write(to: profileURL)
        let original = try Data(contentsOf: authURL)
        let runtime = TestCodexLocalProfileRuntime()
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.invalidProfilePath(profileURL.path)) {
            try await manager.switchToProfile(at: profileURL.path)
        }
        #expect(try Data(contentsOf: authURL) == original)
        #expect(runtime.reopenCallCount == 0)
    }

    @Test
    func `switch closes running processes when confirmation already granted`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let runtime = TestCodexLocalProfileRuntime(
            runningProcesses: CodexLocalProfileRunningProcesses(
                codexAppRunning: true,
                cliProcesses: [.init(id: 99, command: "codex login")]))
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        _ = try await manager.switchToProfile(
            at: profileURL.path,
            confirmedProcesses: runtime.runningProcessesStub)

        #expect(runtime.closeCallCount == 1)
        #expect(runtime.reopenCallCount == 1)
    }

    @Test
    func `switch still succeeds when reopen fails after auth swap`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let runtime = TestCodexLocalProfileRuntime(
            reopenError: .failedToReopenCodexApp("/Applications/Codex.app"))
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: runtime,
            appURL: root.appendingPathComponent("Codex.app"))

        let result = try await manager.switchToProfile(at: profileURL.path)

        #expect(try Data(contentsOf: authURL) == Data(contentsOf: profileURL))
        #expect(result.reopenError == .failedToReopenCodexApp("/Applications/Codex.app"))
    }

    @Test
    func `switch rejects profiles outside saved profiles directory`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let outsideURL = root.appendingPathComponent("outside.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: outsideURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        await #expect(throws: CodexLocalProfileManagerError.invalidProfilePath(outsideURL.path)) {
            try await manager.switchToProfile(at: outsideURL.path)
        }
    }

    @Test
    func `switch hardens backup permissions`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let result = try await manager.switchToProfile(at: profileURL.path)

        let backupURL = try #require(result.backupURL)
        #expect(try self.posixPermissions(at: backupURL.deletingLastPathComponent()) == 0o700)
        #expect(try self.posixPermissions(at: backupURL) == 0o600)
        #expect(try self.posixPermissions(at: authURL) == 0o600)
    }

    @Test
    func `switch creates unique backups on repeated operations`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-b.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Codex.app"),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: TestCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let first = try await manager.switchToProfile(at: profileURL.path)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        let second = try await manager.switchToProfile(at: profileURL.path)

        let firstBackup = try #require(first.backupURL)
        let secondBackup = try #require(second.backupURL)
        #expect(firstBackup != secondBackup)
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: firstBackup.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        #expect(backupFiles.count(where: { $0.pathExtension == "json" }) == 2)
    }

    @Test
    func `runtime detects codex cli when ps comm is a path`() async throws {
        let runtime = DefaultCodexLocalProfileRuntime(
            runningApplicationsProvider: { _ in [] },
            psOutputProvider: {
                """
                  42 /Users/markhardy/.local/bin/codex /Users/markhardy/.local/bin/codex chat
                """
            },
            waitForCLIExitProvider: { _ in [] })

        let processes = try await runtime.runningProcesses()

        #expect(processes.codexAppRunning == false)
        #expect(processes.cliProcesses == [.init(id: 42, command: "/Users/markhardy/.local/bin/codex chat")])
    }

    private func writeAuthFile(to url: URL, email: String, plan: String, accountID: String) throws {
        let token = Self.fakeJWT(email: email, plan: plan)
        let payload: [String: Any] = [
            "tokens": [
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "id_token": token,
                "account_id": accountID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
            "https://api.openai.com/profile": ["email": email],
        ])) ?? Data()
        return "\(self.base64URL(header)).\(self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        return try Int(#require(permissions).intValue)
    }
}

private final class TestCodexLocalProfileRuntime: CodexLocalProfileRuntimeProtocol, @unchecked Sendable {
    let runningProcessesStub: CodexLocalProfileRunningProcesses
    let reopenError: CodexLocalProfileManagerError?
    private(set) var closeCallCount = 0
    private(set) var reopenCallCount = 0

    init(
        runningProcesses: CodexLocalProfileRunningProcesses = .init(codexAppRunning: false, cliProcesses: []),
        reopenError: CodexLocalProfileManagerError? = nil)
    {
        self.runningProcessesStub = runningProcesses
        self.reopenError = reopenError
    }

    func runningProcesses() async throws -> CodexLocalProfileRunningProcesses {
        self.runningProcessesStub
    }

    func close(processes _: CodexLocalProfileRunningProcesses) async throws {
        self.closeCallCount += 1
    }

    func reopenCodexApp(at _: URL) async throws {
        self.reopenCallCount += 1
        if let reopenError {
            throw reopenError
        }
    }
}
