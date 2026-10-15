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

    @Test @MainActor
    func `account mismatch removes the cookies just written for that email`() async {
        let script = PersistentCookieScript()
        script.probe = { "other@example.com" }

        do {
            _ = try await script.commit(targetEmail: "owner@example.com", requireEmailMatch: true)
            Issue.record("Expected the other account to be rejected")
        } catch let error as OpenAIDashboardBrowserCookieImporter.ImportError {
            guard case let .noMatchingAccount(found) = error else {
                Issue.record("Expected noMatchingAccount, got \(error)")
                return
            }
            #expect(found == [
                OpenAIDashboardBrowserCookieImporter.FoundAccount(
                    sourceLabel: "Chrome",
                    email: "other@example.com"),
            ])
        } catch {
            Issue.record("Expected noMatchingAccount, got \(error)")
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict", "clear"])
    }

    @Test @MainActor
    func `login failure removes the cookies just written for that email`() async {
        let script = PersistentCookieScript()
        script.probe = { throw OpenAIDashboardFetcher.FetchError.loginRequired }

        do {
            _ = try await script.commit(targetEmail: "owner@example.com", requireEmailMatch: true)
            Issue.record("Expected login to be rejected")
        } catch let error as OpenAIDashboardBrowserCookieImporter.ImportError {
            guard case .dashboardStillRequiresLogin = error else {
                Issue.record("Expected dashboardStillRequiresLogin, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected dashboardStillRequiresLogin, got \(error)")
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict", "clear"])
    }

    @Test @MainActor
    func `timed out persistent validation keeps the cookies just written`() async {
        let script = PersistentCookieScript()
        script.probe = { throw URLError(.timedOut) }

        do {
            _ = try await script.commit(targetEmail: "owner@example.com", requireEmailMatch: true)
            Issue.record("Expected a timeout")
        } catch {
            #expect(OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(afterPersistFailure: error))
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict"])
    }

    @Test @MainActor
    func `default store keeps cookies when persistent validation times out`() async {
        let script = PersistentCookieScript()
        script.probe = { throw URLError(.timedOut) }

        do {
            _ = try await script.commit(targetEmail: "", requireEmailMatch: false)
            Issue.record("Expected a timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(!OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(afterPersistFailure: error))
        } catch {
            Issue.record("Expected URLError.timedOut, got \(error)")
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict"])
    }

    @Test @MainActor
    func `default store login failure removes the cookies just written`() async {
        let script = PersistentCookieScript()
        script.probe = { throw OpenAIDashboardFetcher.FetchError.loginRequired }

        do {
            _ = try await script.commit(targetEmail: "", requireEmailMatch: false)
            Issue.record("Expected login to be rejected")
        } catch let error as OpenAIDashboardBrowserCookieImporter.ImportError {
            guard case .dashboardStillRequiresLogin = error else {
                Issue.record("Expected dashboardStillRequiresLogin, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected dashboardStillRequiresLogin, got \(error)")
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict", "clear"])
    }

    @Test @MainActor
    func `matching session keeps the cookies it just wrote`() async throws {
        let script = PersistentCookieScript()
        script.probe = { "owner@example.com" }

        let result = try await script.commit(
            targetEmail: "owner@example.com",
            requireEmailMatch: true)

        #expect(result.signedInEmail == "owner@example.com")
        #expect(result.matchesCodexEmail)
        #expect(script.log.snapshot == ["clear", "write", "probe"])
    }

    @Test @MainActor
    func `unrelated probe failure keeps the cookies it just wrote`() async {
        let script = PersistentCookieScript()
        script.probe = { throw OpenAIDashboardFetcher.FetchError.noDashboardData(body: "fixture") }

        do {
            _ = try await script.commit(targetEmail: "owner@example.com", requireEmailMatch: true)
            Issue.record("Expected the probe failure")
        } catch let error as OpenAIDashboardFetcher.FetchError {
            guard case .noDashboardData = error else {
                Issue.record("Expected noDashboardData, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected noDashboardData, got \(error)")
        }

        #expect(script.log.snapshot == ["clear", "write", "probe", "evict"])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func `older rejection cannot erase a newer import on the same account store`() async {
        let jar = TrackedCookieJar()
        let log = CookieOperationLog()
        let entered = CookieCallbackFlag()
        let released = CookieCallbackFlag()
        let newerStarted = CookieCallbackFlag()
        let storeKey = "shared-account"
        defer { released.set() }

        let older = Task { @MainActor in
            try await commitTrackedSession(
                storeKey: storeKey,
                label: "older",
                jar: jar,
                log: log,
                probe: {
                    entered.set()
                    while !released.value {
                        await Task.yield()
                    }
                    throw OpenAIDashboardFetcher.FetchError.loginRequired
                })
        }

        while !entered.value {
            await Task.yield()
        }

        let newer = Task { @MainActor in
            newerStarted.set()
            return try await commitTrackedSession(
                storeKey: storeKey,
                label: "newer",
                jar: jar,
                log: log,
                probe: { "owner@example.com" })
        }

        while !newerStarted.value {
            await Task.yield()
        }
        await Task.yield()
        #expect(jar.owner == "older")

        released.set()
        let olderResult = await older.result
        let newerResult = await newer.result

        guard case let .failure(error) = olderResult else {
            Issue.record("Expected the older import to reject")
            return
        }
        guard let importError = error as? OpenAIDashboardBrowserCookieImporter.ImportError,
              case .dashboardStillRequiresLogin = importError
        else {
            Issue.record("Expected dashboardStillRequiresLogin, got \(error)")
            return
        }
        guard case let .success(result) = newerResult else {
            Issue.record("Expected the newer import to succeed, got \(newerResult)")
            return
        }
        #expect(result.signedInEmail == "owner@example.com")
        #expect(jar.owner == "newer")
        #expect(log.snapshot == [
            "older clear",
            "older write",
            "older probe",
            "older evict",
            "older clear",
            "newer clear",
            "newer write",
            "newer probe",
        ])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func `an in-flight import does not block a different account store`() async throws {
        let olderJar = TrackedCookieJar()
        let newerJar = TrackedCookieJar()
        let log = CookieOperationLog()
        let entered = CookieCallbackFlag()
        let released = CookieCallbackFlag()
        let newerFinished = CookieCallbackFlag()
        defer { released.set() }

        let older = Task { @MainActor in
            try await commitTrackedSession(
                storeKey: "account-a",
                label: "older",
                jar: olderJar,
                log: log,
                probe: {
                    entered.set()
                    while !released.value {
                        await Task.yield()
                    }
                    return "owner@example.com"
                })
        }

        while !entered.value {
            await Task.yield()
        }

        let newer = Task { @MainActor in
            let result = try await commitTrackedSession(
                storeKey: "account-b",
                label: "newer",
                jar: newerJar,
                log: log,
                probe: { "owner@example.com" })
            newerFinished.set()
            return result
        }

        while !newerFinished.value {
            try Task.checkCancellation()
            await Task.yield()
        }
        #expect(newerFinished.value)
        #expect(olderJar.owner == "older")
        #expect(newerJar.owner == "newer")

        released.set()
        _ = try await older.value
        let newerResult = try await newer.value
        #expect(newerResult.signedInEmail == "owner@example.com")
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func `waiting account transaction respects deadline and cancellation`() async throws {
        let key = UUID().uuidString
        var release: CheckedContinuation<Void, Never>?
        let holder = Task {
            try await OpenAIDashboardBrowserCookieImporter.withPersistentCookieTransaction(key: key, deadline: nil) {
                await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil {
            await Task.yield()
        }
        defer { release?.resume() }
        var touched = false
        do {
            try await OpenAIDashboardBrowserCookieImporter.withPersistentCookieTransaction(
                key: key, deadline: Date().addingTimeInterval(0.03)) { touched = true }
            Issue.record("Expected the waiting transaction to time out")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        var started = false
        let cancelled = Task {
            started = true
            try await OpenAIDashboardBrowserCookieImporter.withPersistentCookieTransaction(key: key, deadline: nil) {
                touched = true
            }
        }
        while !started {
            await Task.yield()
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            Issue.record("Expected cancellation while the first transaction is held")
        } catch is CancellationError {}
        #expect(!touched)
        release?.resume()
        release = nil
        try await holder.value
        try await OpenAIDashboardBrowserCookieImporter.withPersistentCookieTransaction(
            key: key, deadline: Date().addingTimeInterval(1)) { touched = true }
        #expect(touched)
    }
}

@MainActor
private final class PersistentCookieScript {
    let log = CookieOperationLog()
    var probe: @MainActor () async throws -> String? = { "owner@example.com" }

    func commit(
        targetEmail: String,
        requireEmailMatch: Bool,
        storeKey: String = UUID().uuidString) async throws -> OpenAIDashboardBrowserCookieImporter.ImportResult
    {
        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: BrowserDetection(cacheTTL: 0))
        return try await importer.commitPersistentCookieSession(
            candidate: .init(label: "Chrome", cookies: []),
            targetEmail: requireEmailMatch ? targetEmail : nil,
            storeKey: storeKey,
            actions: OpenAIDashboardBrowserCookieImporter.PersistentCookieSessionActions(
                clearExisting: { self.log.append("clear") },
                writeCandidate: { self.log.append("write") },
                probeSignedInEmail: {
                    self.log.append("probe")
                    return try await self.probe()
                },
                evictWebView: { self.log.append("evict") }),
            logger: { _ in })
    }
}

@MainActor
private final class TrackedCookieJar {
    private(set) var owner: String?

    func clear() {
        self.owner = nil
    }

    func write(_ label: String) {
        self.owner = label
    }
}

@MainActor
private func commitTrackedSession(
    storeKey: String,
    label: String,
    jar: TrackedCookieJar,
    log: CookieOperationLog,
    probe: @escaping @MainActor () async throws -> String?) async throws
    -> OpenAIDashboardBrowserCookieImporter.ImportResult
{
    let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: BrowserDetection(cacheTTL: 0))
    return try await importer.commitPersistentCookieSession(
        candidate: .init(label: label, cookies: []),
        targetEmail: "owner@example.com",
        storeKey: storeKey,
        actions: OpenAIDashboardBrowserCookieImporter.PersistentCookieSessionActions(
            clearExisting: {
                jar.clear()
                log.append("\(label) clear")
            },
            writeCandidate: {
                jar.write(label)
                log.append("\(label) write")
            },
            probeSignedInEmail: {
                log.append("\(label) probe")
                return try await probe()
            },
            evictWebView: { log.append("\(label) evict") }),
        logger: { _ in })
}
