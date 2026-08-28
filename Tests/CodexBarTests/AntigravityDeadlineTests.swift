import Foundation
import Testing
@testable import CodexBarCore

private final class AntigravityTimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []

    func append(_ timeout: TimeInterval) {
        self.lock.withLock {
            self.timeouts.append(timeout)
        }
    }

    func snapshot() -> [TimeInterval] {
        self.lock.withLock {
            self.timeouts
        }
    }
}

private final class AntigravityConcurrencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActiveCount = 0

    func begin() {
        self.lock.withLock {
            self.activeCount += 1
            self.maximumActiveCount = max(self.maximumActiveCount, self.activeCount)
        }
    }

    func end() {
        self.lock.withLock {
            self.activeCount -= 1
        }
    }

    func maximum() -> Int {
        self.lock.withLock {
            self.maximumActiveCount
        }
    }
}

struct AntigravityDeadlineTests {
    @Test
    func `process candidates probe concurrently while preserving result order`() async throws {
        let processInfos = [
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 1,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "first",
                commandLine: "first"),
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 2,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "second",
                commandLine: "second"),
        ]
        let concurrency = AntigravityConcurrencyRecorder()

        let result = try await AntigravityStatusProbe.fetchProcessSnapshots(
            processInfos: processInfos)
        { processInfo in
            concurrency.begin()
            defer { concurrency.end() }
            if processInfo.pid == 1 {
                try await Task.sleep(for: .milliseconds(120))
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
            return AntigravityStatusSnapshot(
                modelQuotas: [],
                accountEmail: "\(processInfo.pid)@example.com",
                accountPlan: nil)
        }

        #expect(concurrency.maximum() == 2)
        #expect(result.snapshots.map(\.accountEmail) == ["1@example.com", "2@example.com"])
        #expect(result.lastError == nil)
    }

    @Test
    func `process candidate transport error preserves url error identity`() async throws {
        let processInfo = AntigravityStatusProbe.ProcessInfoResult(
            pid: 1,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "token",
            commandLine: "command")

        let result = try await AntigravityStatusProbe.fetchProcessSnapshots(processInfos: [processInfo]) { _ in
            throw URLError(.cannotConnectToHost)
        }

        #expect((result.lastError as? URLError)?.code == .cannotConnectToHost)
    }

    @Test
    func `process candidate cancellation rejects partial success`() async {
        let processInfos = [
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 1,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "first",
                commandLine: "first"),
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 2,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "second",
                commandLine: "second"),
        ]

        await #expect(throws: CancellationError.self) {
            try await AntigravityStatusProbe.fetchProcessSnapshots(processInfos: processInfos) { processInfo in
                if processInfo.pid == 2 {
                    throw CancellationError()
                }
                return AntigravityStatusSnapshot(
                    modelQuotas: [],
                    accountEmail: "partial@example.com",
                    accountPlan: nil)
            }
        }
    }

    @Test
    func `cancelled process request rejects partial success`() async {
        let processInfos = [
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 1,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "first",
                commandLine: "first"),
            AntigravityStatusProbe.ProcessInfoResult(
                pid: 2,
                extensionPort: nil,
                extensionServerCSRFToken: nil,
                csrfToken: "second",
                commandLine: "second"),
        ]

        await #expect(throws: CancellationError.self) {
            try await AntigravityStatusProbe.fetchProcessSnapshots(processInfos: processInfos) { processInfo in
                if processInfo.pid == 2 {
                    throw URLError(.cancelled)
                }
                return AntigravityStatusSnapshot(
                    modelQuotas: [],
                    accountEmail: "partial@example.com",
                    accountPlan: nil)
            }
        }
    }

    @Test
    func `shared deadline reserves time for later endpoint probes`() async throws {
        let endpoints = [
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 64001,
                csrfToken: "token",
                source: .languageServer),
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 64002,
                csrfToken: "token",
                source: .languageServer),
        ]
        let recorder = AntigravityTimeoutRecorder()
        let deadline = Date().addingTimeInterval(2)

        let resolved = try await AntigravityStatusProbe.resolveWorkingEndpoint(
            candidateEndpoints: endpoints,
            timeout: 1,
            deadline: deadline,
            testConnectivity: { endpoint, timeout in
                recorder.append(timeout)
                if endpoint.port == 64001 {
                    try? await Task.sleep(for: .seconds(timeout))
                    return false
                }
                return true
            })

        let timeouts = recorder.snapshot()
        #expect(resolved.port == 64002)
        #expect(timeouts.count == 2)
        #expect(timeouts[0] < 1.1)
        #expect(timeouts[1] > 0)
    }
}
