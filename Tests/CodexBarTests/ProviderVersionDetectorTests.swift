import XCTest
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ProviderVersionDetectorTests: XCTestCase {
    func test_run_returnsFirstLineForSuccessfulCommand() {
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "printf 'gemini 1.2.3\\nextra\\n'"],
            timeout: 1.0)

        XCTAssertEqual(version, "gemini 1.2.3")
    }

    func test_run_returnsNilAfterTimeout() {
        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "sleep 5"],
            timeout: 0.1)
        let duration = Date().timeIntervalSince(start)

        XCTAssertNil(version)
        XCTAssertLessThan(duration, 2.0)
    }

    func test_run_returnsOutputWhenDetachedChildKeepsPipeOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-version-drain-\(UUID().uuidString)", isDirectory: true)
        let childPIDFile = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(childPID, SIGKILL)
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_TEST_CHILD_PID_FILE"] = childPIDFile.path
        let script = """
        (trap '' HUP; sleep 5) &
        child=$!
        printf '%s' "$child" > "$CODEXBAR_TEST_CHILD_PID_FILE"
        printf 'grok 1.2.3\\n'
        """

        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", script],
            timeout: 1.0,
            environment: environment)
        let duration = Date().timeIntervalSince(start)

        XCTAssertEqual(version, "grok 1.2.3")
        XCTAssertLessThan(duration, 2.0)
        let childPID = try XCTUnwrap(
            pid_t(String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(childPID, 0), 0, "Descendant should still hold the inherited pipe open")
    }

    override func setUp() {
        super.setUp()
        ProviderVersionDetector.resetHooksAndCache()
    }

    override func tearDown() {
        ProviderVersionDetector.resetHooksAndCache()
        super.tearDown()
    }

    private final class MockDetectorState {
        var callCount = 0
        var runDelay: TimeInterval?
        var runnerResult: TTYCommandRunner.Result? = .init(
            text: "claude-code 2.1.70",
            completion: .processExited(status: 0))
        let lock = NSLock()

        func increment() -> TTYCommandRunner.Result? {
            self.lock.lock()
            self.callCount += 1
            let delay = self.runDelay
            let res = self.runnerResult
            self.lock.unlock()
            if let delay {
                Thread.sleep(forTimeInterval: delay)
            }
            return res
        }

        func setResult(text: String, completion: TTYCommandRunner.Result.Completion = .processExited(status: 0)) {
            self.lock.lock()
            self.runnerResult = .init(text: text, completion: completion)
            self.lock.unlock()
        }
    }

    func test_claudeVersion_cachesSuccessfulResult() {
        let state = MockDetectorState()
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        let first = Self.userInitiatedClaudeVersion()
        XCTAssertEqual(first, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        let second = Self.userInitiatedClaudeVersion()
        XCTAssertEqual(second, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)
    }

    func test_claudeVersion_productionPathProof() {
        let state = MockDetectorState()
        var size = 5000
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: size),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        let cold = Self.userInitiatedClaudeVersion()
        let warm = Self.userInitiatedClaudeVersion()
        size = 6000
        let afterFingerprintChange = Self.userInitiatedClaudeVersion()

        print(
            "ProviderVersionDetector proof: cold=\(cold ?? "nil") "
                + "warm=\(warm ?? "nil") "
                + "afterFingerprintChange=\(afterFingerprintChange ?? "nil") "
                + "productionProbeCount=\(state.callCount)")
        XCTAssertEqual(cold, "claude-code 2.1.70")
        XCTAssertEqual(warm, "claude-code 2.1.70")
        XCTAssertEqual(afterFingerprintChange, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_backgroundColdDetectionSkipsChildAndUsesFallback() async {
        let state = MockDetectorState()
        self.configureClaudeVersionHooks(state: state)

        let userAgent = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    ProviderInteractionContext.$current.withValue(.background) {
                        ClaudeOAuthUsageFetcher._userAgentForTesting(
                            detectClaudeVersion: true,
                            versionDetector: { ProviderVersionDetector.claudeVersion(environment: [:]) })
                    }
                }
            }
        }

        XCTAssertEqual(userAgent, "claude-code/2.1.0")
        XCTAssertEqual(state.callCount, 0)
    }

    func test_claudeVersion_disabledKeychainWithoutMarkerStillSkipsChild() async throws {
        let state = MockDetectorState()
        self.configureClaudeVersionHooks(state: state)
        let profile = try self.makeClaudeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }

        let version = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            KeychainAccessGate.withTaskOverrideForTesting(true) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    ProviderInteractionContext.$current.withValue(.background) {
                        ProviderVersionDetector.claudeVersion(environment: profile.environment)
                    }
                }
            }
        }

        XCTAssertNil(version)
        XCTAssertEqual(state.callCount, 0)
    }

    func test_claudeVersion_userInitiatedColdDetectionRunsChild() async {
        let state = MockDetectorState()
        self.configureClaudeVersionHooks(state: state)

        let version = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ProviderInteractionContext.$current.withValue(.userInitiated) {
                ProviderVersionDetector.claudeVersion(environment: [:])
            }
        }

        XCTAssertEqual(version, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)
    }

    func test_claudeVersion_establishedBackgroundWithPromptOptInRunsChild() async throws {
        let state = MockDetectorState()
        self.configureClaudeVersionHooks(state: state)
        let profile = try self.makeClaudeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }

        let version = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/mock/bin/claude", environment: profile.environment)
            return KeychainAccessGate.withTaskOverrideForTesting(false) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    ProviderInteractionContext.$current.withValue(.background) {
                        ProviderVersionDetector.claudeVersion(environment: profile.environment)
                    }
                }
            }
        }

        XCTAssertEqual(version, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)
    }

    func test_claudeVersion_cachedValueRemainsAvailableInUnconsentedBackground() async {
        let state = MockDetectorState()
        self.configureClaudeVersionHooks(state: state)

        let cold = ProviderInteractionContext.$current.withValue(.userInitiated) {
            ProviderVersionDetector.claudeVersion(environment: [:])
        }
        let cached = await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ProviderInteractionContext.$current.withValue(.background) {
                        ProviderVersionDetector.claudeVersion(environment: [:])
                    }
                }
            }
        }

        XCTAssertEqual(cold, "claude-code 2.1.70")
        XCTAssertEqual(cached, "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)
    }

    func test_claudeVersion_realExecutableProof() throws {
        guard ProcessInfo.processInfo.environment["LIVE_CLAUDE_TTY"] == "1" else {
            throw XCTSkip("Set LIVE_CLAUDE_TTY=1 to probe the installed Claude executable")
        }
        guard let path = TTYCommandRunner.which("claude") else {
            throw XCTSkip("claude executable is not installed in PATH")
        }

        let direct = try XCTUnwrap(ProviderVersionDetector.run(path: path, args: ["--version"]))
        let cold = try XCTUnwrap(Self.userInitiatedClaudeVersion())
        let warm = try XCTUnwrap(Self.userInitiatedClaudeVersion())

        print(
            "Claude real executable proof: path=\(URL(fileURLWithPath: path).lastPathComponent) "
                + "direct=\(direct) cold=\(cold) warm=\(warm)")
        XCTAssertEqual(cold, direct)
        XCTAssertEqual(warm, direct)
    }

    func test_claudeVersion_coalescesConcurrentProbes() {
        let state = MockDetectorState()
        state.runDelay = 0.1
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        let totalThreads = 20
        let semaphore = DispatchSemaphore(value: 0)

        for _ in 0..<totalThreads {
            DispatchQueue.global().async {
                let res = Self.userInitiatedClaudeVersion()
                XCTAssertEqual(res, "claude-code 2.1.70")
                semaphore.signal()
            }
        }

        for _ in 0..<totalThreads {
            let result = semaphore.wait(timeout: .now() + 2.0)
            XCTAssertEqual(result, .success, "Concurrent call timed out")
        }

        XCTAssertEqual(state.callCount, 1)
    }

    func test_claudeVersion_invalidatesOnModificationDateChange() {
        let state = MockDetectorState()
        var modDate = Date(timeIntervalSince1970: 1000)
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: modDate,
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        modDate = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_invalidatesOnSizeOrInodeOrPathChange() {
        let state = MockDetectorState()
        var path = "/mock/bin/claude"
        var size = 5000
        var inode = 99
        ProviderVersionDetector.whichHook = { _ in path }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: size),
                .systemFileNumber: NSNumber(value: inode),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        size = 6000
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)

        inode = 100
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 3)

        path = "/mock/bin/claude2"
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 4)
    }

    func test_claudeVersion_doesNotCacheFailurePermanently() {
        let state = MockDetectorState()
        state.runnerResult = nil
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 1)

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 2)

        state.setResult(text: "claude-code 2.1.70")

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 3)

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 3)
    }

    func test_claudeVersion_doesNotCacheEmptyOutput() {
        let state = MockDetectorState()
        state.setResult(text: "  ")
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 1)

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_doesNotCacheNonzeroExitDiagnostics() {
        let state = MockDetectorState()
        state.setResult(
            text: "claude-code 2.1.70 failed to load",
            completion: .processExited(status: 1))
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in state.increment() }

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 1)

        state.setResult(text: "claude-code 2.1.70")
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_doesNotCacheDeadlineOutput() {
        let state = MockDetectorState()
        state.setResult(text: "claude-code 2.1.70", completion: .deadlineExceeded)
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in state.increment() }

        XCTAssertNil(Self.userInitiatedClaudeVersion())
        XCTAssertEqual(state.callCount, 1)

        state.setResult(text: "claude-code 2.1.70")
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_refreshesStableWrapperAfterTTL() {
        let state = MockDetectorState()
        var now = Date(timeIntervalSince1970: 10000)
        ProviderVersionDetector.nowHook = { now }
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in state.increment() }

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        state.setResult(text: "claude-code 2.1.71")
        now.addTimeInterval(ProviderVersionDetector.claudeVersionCacheTTL - 1)
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        now.addTimeInterval(2)
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.71")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_refreshesAfterClockRollback() {
        let state = MockDetectorState()
        var now = Date(timeIntervalSince1970: 10000)
        ProviderVersionDetector.nowHook = { now }
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in state.increment() }

        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.70")
        XCTAssertEqual(state.callCount, 1)

        state.setResult(text: "claude-code 2.1.71")
        now.addTimeInterval(-1)
        XCTAssertEqual(Self.userInitiatedClaudeVersion(), "claude-code 2.1.71")
        XCTAssertEqual(state.callCount, 2)
    }

    func test_claudeVersion_benchmark1000SequentialCalls() {
        let state = MockDetectorState()
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in
            state.increment()
        }

        for _ in 0..<1000 {
            _ = Self.userInitiatedClaudeVersion()
        }

        XCTAssertEqual(state.callCount, 1)
    }

    private func configureClaudeVersionHooks(state: MockDetectorState) {
        ProviderVersionDetector.whichHook = { _ in "/mock/bin/claude" }
        ProviderVersionDetector.attributesHook = { _ in
            [
                .modificationDate: Date(timeIntervalSince1970: 1000),
                .size: NSNumber(value: 5000),
                .systemFileNumber: NSNumber(value: 99),
            ]
        }
        ProviderVersionDetector.runClaudeVersionHook = { _ in state.increment() }
    }

    private static func userInitiatedClaudeVersion() -> String? {
        ProviderInteractionContext.$current.withValue(.userInitiated) {
            ProviderVersionDetector.claudeVersion()
        }
    }

    private func makeClaudeProfile(accountID: String) throws -> (
        root: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-version-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (root: root, environment: ["CLAUDE_CONFIG_DIR": root.path])
    }
}
