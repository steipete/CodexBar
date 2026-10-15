import Foundation
import Testing
@testable import CodexBarCore

private final class CookieCallbackHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    func capture(_ callback: @escaping @Sendable () -> Void) {
        self.lock.withLock { self.callback = callback }
    }

    func finish() {
        let callback = self.lock.withLock {
            let callback = self.callback
            self.callback = nil
            return callback
        }
        callback?()
    }
}

private final class CookieCallbackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        self.lock.withLock { self.storedValue }
    }

    func set() {
        self.lock.withLock { self.storedValue = true }
    }
}

private final class CookieOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var snapshot: [String] {
        self.lock.withLock { self.entries }
    }

    func append(_ entry: String) {
        self.lock.withLock { self.entries.append(entry) }
    }
}

struct OpenAIDashboardBrowserCookieImporterTests {
    @Test
    func `profile denial names exact running component`() {
        let hint = OpenAIDashboardBrowserCookieImporter.browserProfileAccessHint(
            for: .chrome,
            issue: .accessDenied,
            processName: "CodexBarCLI",
            executablePath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")

        #expect(hint.contains("macOS denied Chrome profile access"))
        #expect(hint.contains("CodexBarCLI (/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI)"))
        #expect(hint.contains("Full Disk Access"))
    }

    @Test
    func `profile denial names app bundle for menu refresh`() {
        let hint = OpenAIDashboardBrowserCookieImporter.browserProfileAccessHint(
            for: .chrome,
            issue: .accessDenied,
            processName: "CodexBar",
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar")

        #expect(hint.contains("CodexBar.app (/Applications/CodexBar.app)"))
    }

    @Test
    func `browser cookie timeout remains distinct from permission denial`() {
        let error = OpenAIDashboardBrowserCookieImporter.browserCookieLoadTimeoutError(
            for: .chrome,
            processName: "CodexBarCLI",
            executablePath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")

        if case .browserCookieLoadTimedOut = error {
            // Expected: a shared deadline does not prove macOS denied access.
        } else {
            Issue.record("Expected browser cookie load timeout")
        }
        #expect(error.localizedDescription.contains("Chrome did not finish before the web timeout"))
        #expect(!error.localizedDescription.contains("access denied"))
        #expect(error.localizedDescription.contains("CodexBarCLI"))
        #expect(error.localizedDescription.contains("Keychain prompt"))
        #expect(error.localizedDescription.contains("Full Disk Access"))
    }

    @Test
    func `shared deadline clamps each local timeout to remaining budget`() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = start.addingTimeInterval(30)

        let remaining = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
            until: deadline,
            cappedAt: 10,
            now: start.addingTimeInterval(27))

        #expect(remaining == 3)
    }

    @Test
    func `shared deadline preserves smaller local timeout`() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = start.addingTimeInterval(30)

        let remaining = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
            until: deadline,
            cappedAt: 10,
            now: start.addingTimeInterval(5))

        #expect(remaining == 10)
    }

    @Test
    func `expired shared deadline throws structured timeout`() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1000)

        do {
            _ = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
                until: deadline,
                now: deadline)
            Issue.record("Expected deadline timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `blocking browser cookie load cannot exceed shared deadline`() async throws {
        let timeoutProbe = CookieCallbackFlag()
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }

        do {
            _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieLoad(
                deadline: Date().addingTimeInterval(0.05),
                timeoutObserver: timeoutProbe.set)
            {
                defer { finished.signal() }
                #expect(release.wait(timeout: .now() + 60) == .success)
                return true
            }
            Issue.record("Expected cookie load timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(timeoutProbe.value)
        release.signal()
        let completion = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: finished.wait(timeout: .now() + 30))
            }
        }
        #expect(completion == .success)
    }

    @Test
    func `timeout observer stays silent when operation wins`() async throws {
        let timeoutProbe = CookieCallbackFlag()

        let value = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieLoad(
            deadline: Date().addingTimeInterval(0.05),
            timeoutObserver: timeoutProbe.set)
        {
            true
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(value)
        #expect(!timeoutProbe.value)
    }

    @Test
    func `bounded cookie loads preserve explicit retry context`() async throws {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        for deadline in [nil, Date().addingTimeInterval(1)] {
            BrowserCookieAccessGate.resetForTesting()

            let allowed = try await BrowserCookieAccessGate.withExplicitRetry {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieLoad(deadline: deadline) {
                        KeychainAccessGate.withTaskOverrideForTesting(false) {
                            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                                .interactionRequired
                            } operation: {
                                ProviderInteractionContext.current == .userInitiated &&
                                    BrowserCookieAccessGate.shouldAttempt(.arc)
                            }
                        }
                    }
                }
            }
            #expect(allowed)
        }
    }

    @Test
    func `timed out cookie cache work stays ordered before retry`() async throws {
        let log = CookieOperationLog()
        let firstOperationStarted = DispatchSemaphore(value: 0)
        let allowFirstOperationToFinish = DispatchSemaphore(value: 0)

        do {
            _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieCacheOperation(
                deadline: Date().addingTimeInterval(0.05))
            {
                log.append("first-start")
                firstOperationStarted.signal()
                _ = allowFirstOperationToFinish.wait(timeout: .now() + 5)
                log.append("first-end")
                return true
            }
            Issue.record("Expected first cache operation timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let firstOperationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: firstOperationStarted.wait(timeout: .now() + 5))
            }
        }
        #expect(firstOperationStartResult == .success)
        do {
            _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieCacheOperation(
                deadline: Date().addingTimeInterval(0.05))
            {
                log.append("second")
                return true
            }
            Issue.record("Expected retry to wait behind first cache operation")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        allowFirstOperationToFinish.signal()

        _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieCacheOperation(
            deadline: Date().addingTimeInterval(1)) { true }
        #expect(log.snapshot == ["first-start", "first-end", "second"])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func `slow callback times out before completion`() async throws {
        let timeoutProbe = CookieCallbackFlag()
        let callback = CookieCallbackHarness()
        defer { callback.finish() }

        do {
            try await OpenAIDashboardBrowserCookieImporter.runBoundedCallback(
                deadline: Date().addingTimeInterval(0.05),
                timeoutObserver: timeoutProbe.set)
            { completion in
                callback.capture(completion)
            }
            Issue.record("Expected callback timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(timeoutProbe.value)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func `slow value callback times out before completion`() async throws {
        let timeoutProbe = CookieCallbackFlag()
        let callback = CookieCallbackHarness()
        defer { callback.finish() }

        do {
            let _: [String] = try await OpenAIDashboardBrowserCookieImporter.runBoundedValueCallback(
                deadline: Date().addingTimeInterval(0.05),
                timeoutObserver: timeoutProbe.set)
            { completion in
                callback.capture { completion([]) }
            }
            Issue.record("Expected value callback timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(timeoutProbe.value)
    }

    @Test @MainActor
    func `retry waits for timed out cookie store mutation`() async throws {
        let keyOwner = NSObject()
        let key = ObjectIdentifier(keyOwner)
        let first = CookieCallbackHarness()

        do {
            try await OpenAIDashboardBrowserCookieImporter.runSerializedCallback(
                key: key,
                deadline: Date().addingTimeInterval(0.05),
                start: first.capture)
            Issue.record("Expected first mutation timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }

        let secondStarted = CookieCallbackFlag()
        let second = Task { @MainActor in
            try await OpenAIDashboardBrowserCookieImporter.runSerializedCallback(
                key: key,
                deadline: Date().addingTimeInterval(1))
            { completion in
                secondStarted.set()
                completion()
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!secondStarted.value)
        first.finish()
        try await second.value
        #expect(secondStarted.value)
    }

    @Test
    func `mismatch error mentions source label`() {
        let err = OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
            found: [
                .init(sourceLabel: "Safari", email: "a@example.com"),
                .init(sourceLabel: "Chrome", email: "b@example.com"),
            ])
        let msg = err.localizedDescription
        #expect(msg.contains("Safari=a@example.com"))
        #expect(msg.contains("Chrome=b@example.com"))
    }

    @Test
    func `timed out persistent validation keeps verified session`() {
        let failure = OpenAIDashboardBrowserCookieImporter.persistentValidationFailure(URLError(.timedOut))
        #expect(OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: failure))
    }

    @Test
    func `raw cookie mutation timeout is not trusted`() {
        #expect(!OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: URLError(.timedOut)))
    }

    @Test
    func `non-timeout persistent validation failures are not trusted`() {
        #expect(!OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin))
    }
}
