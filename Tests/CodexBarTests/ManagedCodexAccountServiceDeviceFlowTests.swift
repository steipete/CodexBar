import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ManagedCodexAccountServiceDeviceFlowTests {
    @Test
    func `device flow writes auth json and returns managed account with provider id`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileManagedCodexAccountStore(
            fileURL: root.appendingPathComponent("managed.json"),
            fileManager: .default)
        let deviceFlowRunner = StubManagedCodexDeviceFlowRunner(
            deviceCode: CodexDeviceFlow.DeviceCodeResponse(
                userCode: "CODE-1234",
                deviceAuthID: "auth-id",
                intervalSeconds: 5,
                verificationURL: URL(string: "https://auth.openai.com/codex/device?user_code=CODE-1234")!),
            credentials: CodexOAuthCredentials(
                accessToken: "access-abc",
                refreshToken: "refresh-abc",
                idToken: "id-token-abc",
                accountId: "workspace-personal",
                lastRefresh: Date()))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactoryForDeviceFlow(root: root),
            loginRunner: UnusedManagedCodexLoginRunnerForDeviceFlow(),
            deviceFlowRunner: deviceFlowRunner,
            identityReader: StubManagedCodexIdentityReaderForDeviceFlow(accounts: [
                .init(
                    identity: .providerAccount(id: "workspace-personal"),
                    email: "user@example.com",
                    plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolverForDeviceFlow())

        let phases = PhaseRecorder()
        let account = try await service.authenticateManagedAccountWithDeviceFlow(
            sessionTimeout: 60,
            progress: { phase in phases.append(phase) })

        #expect(account.email == "user@example.com")
        #expect(account.providerAccountID == "workspace-personal")
        let storedSnapshot = try store.loadAccounts()
        #expect(storedSnapshot.accounts.count == 1)

        let recorded = phases.snapshot()
        #expect(recorded.count == 3)
        #expect(recorded.first == .requestingCode)
        #expect(recorded[1] == .awaitingUser(
            userCode: "CODE-1234",
            verificationURL: URL(string: "https://auth.openai.com/codex/device?user_code=CODE-1234")!))
        #expect(recorded.last == .exchangingTokens)

        let authFile = URL(fileURLWithPath: account.managedHomePath)
            .appendingPathComponent("auth.json")
        #expect(FileManager.default.fileExists(atPath: authFile.path))

        let data = try Data(contentsOf: authFile)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let json = try #require(decoded as? [String: Any])
        let tokens = try #require(json["tokens"] as? [String: Any])
        #expect(tokens["access_token"] as? String == "access-abc")
        #expect(tokens["refresh_token"] as? String == "refresh-abc")
        #expect(tokens["id_token"] as? String == "id-token-abc")
        #expect(tokens["account_id"] as? String == "workspace-personal")
    }

    @Test
    func `device flow timeout surfaces mapped service error and removes managed home`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileManagedCodexAccountStore(
            fileURL: root.appendingPathComponent("managed.json"),
            fileManager: .default)
        let homeFactory = TestManagedCodexHomeFactoryForDeviceFlow(root: root)
        let deviceFlowRunner = StubManagedCodexDeviceFlowRunner(
            deviceCode: CodexDeviceFlow.DeviceCodeResponse(
                userCode: "CODE-1234",
                deviceAuthID: "auth-id",
                intervalSeconds: 5,
                verificationURL: URL(string: "https://auth.openai.com/codex/device?user_code=CODE-1234")!),
            credentials: nil,
            pollError: CodexDeviceFlow.Error.timedOut)
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: homeFactory,
            loginRunner: UnusedManagedCodexLoginRunnerForDeviceFlow(),
            deviceFlowRunner: deviceFlowRunner,
            identityReader: StubManagedCodexIdentityReaderForDeviceFlow(accounts: []),
            workspaceResolver: StubManagedCodexWorkspaceResolverForDeviceFlow())

        var caught: Error?
        do {
            _ = try await service.authenticateManagedAccountWithDeviceFlow(
                sessionTimeout: 60,
                progress: { _ in })
        } catch {
            caught = error
        }

        let serviceError = try #require(caught as? ManagedCodexAccountServiceError)
        #expect(serviceError == .deviceFlowTimedOut)
        let storedSnapshot = try store.loadAccounts()
        #expect(storedSnapshot.accounts.isEmpty)

        // The managed home must be cleaned up on failure.
        if let homePath = homeFactory.lastHandedOutPath {
            #expect(FileManager.default.fileExists(atPath: homePath) == false)
        }
    }
}

// MARK: - stubs scoped to this test suite (prefixed to avoid collision with existing service tests)

@MainActor
private final class PhaseRecorder {
    private var phases: [ManagedCodexDeviceFlowProgress] = []
    func append(_ phase: ManagedCodexDeviceFlowProgress) {
        self.phases.append(phase)
    }

    func snapshot() -> [ManagedCodexDeviceFlowProgress] {
        self.phases
    }
}

private final class TestManagedCodexHomeFactoryForDeviceFlow: ManagedCodexHomeProducing, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var index: Int = 0
    private(set) var lastHandedOutPath: String?

    init(root: URL) {
        self.root = root
    }

    func makeHomeURL() -> URL {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.index += 1
        let url = self.root.appendingPathComponent("accounts/account-\(self.index)", isDirectory: true)
        self.lastHandedOutPath = url.path
        return url
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct UnusedManagedCodexLoginRunnerForDeviceFlow: ManagedCodexLoginRunning {
    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        // The device-auth method must never reach the CLI runner.
        CodexLoginRunner.Result(outcome: .failed(status: -1), output: "unexpected")
    }
}

private final class StubManagedCodexDeviceFlowRunner: ManagedCodexDeviceFlowRunning, @unchecked Sendable {
    let deviceCode: CodexDeviceFlow.DeviceCodeResponse
    let credentials: CodexOAuthCredentials?
    let requestError: Error?
    let pollError: Error?

    init(
        deviceCode: CodexDeviceFlow.DeviceCodeResponse,
        credentials: CodexOAuthCredentials?,
        requestError: Error? = nil,
        pollError: Error? = nil)
    {
        self.deviceCode = deviceCode
        self.credentials = credentials
        self.requestError = requestError
        self.pollError = pollError
    }

    func requestDeviceCode() async throws -> CodexDeviceFlow.DeviceCodeResponse {
        if let requestError { throw requestError }
        return self.deviceCode
    }

    func pollForTokens(
        deviceAuthID _: String,
        userCode _: String,
        intervalSeconds _: Int,
        deadline _: Date) async throws -> CodexOAuthCredentials
    {
        if let pollError { throw pollError }
        guard let credentials else {
            throw CodexDeviceFlow.Error.invalidResponse
        }
        return credentials
    }
}

private final class StubManagedCodexIdentityReaderForDeviceFlow: ManagedCodexIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [CodexAuthBackedAccount]

    init(accounts: [CodexAuthBackedAccount]) {
        self.identities = accounts
    }

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.identities.isEmpty else {
            return CodexAuthBackedAccount(identity: .unresolved, email: nil, plan: nil)
        }
        return self.identities.removeFirst()
    }
}

private struct StubManagedCodexWorkspaceResolverForDeviceFlow: ManagedCodexWorkspaceResolving {
    func resolveWorkspaceIdentity(
        homePath _: String,
        providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: providerAccountID,
            workspaceLabel: "Test Workspace")
    }
}
