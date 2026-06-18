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

    @Test
    func `blocking browser cookie load cannot exceed shared deadline`() async {
        let start = Date()

        do {
            _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieLoad(
                deadline: start.addingTimeInterval(0.05))
            {
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
            Issue.record("Expected cookie load timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(Date().timeIntervalSince(start) < 0.3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `timed out cookie cache work stays ordered before retry`() async throws {
        let log = CookieOperationLog()

        do {
            _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieCacheOperation(
                deadline: Date().addingTimeInterval(0.05))
            {
                log.append("first-start")
                Thread.sleep(forTimeInterval: 0.15)
                log.append("first-end")
                return true
            }
            Issue.record("Expected first cache operation timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }

        _ = try await OpenAIDashboardBrowserCookieImporter.runBoundedCookieCacheOperation(
            deadline: Date().addingTimeInterval(1))
        {
            log.append("second")
            return true
        }
        #expect(log.snapshot == ["first-start", "first-end", "second"])
    }

    @Test @MainActor
    func `stalled callback cannot exceed shared deadline`() async {
        let start = Date()

        do {
            try await OpenAIDashboardBrowserCookieImporter.runBoundedCallback(
                deadline: start.addingTimeInterval(0.05))
            { _ in }
            Issue.record("Expected callback timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(Date().timeIntervalSince(start) < 0.3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func `stalled value callback cannot exceed shared deadline`() async {
        let start = Date()

        do {
            let _: [String] = try await OpenAIDashboardBrowserCookieImporter.runBoundedValueCallback(
                deadline: start.addingTimeInterval(0.05))
            { _ in }
            Issue.record("Expected value callback timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(Date().timeIntervalSince(start) < 0.3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
