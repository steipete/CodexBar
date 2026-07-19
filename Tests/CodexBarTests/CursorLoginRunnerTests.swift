import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorLoginRunnerTests {
    private static let cometApplicationURL = URL(fileURLWithPath: "/Applications/Comet.app")

    private final class LockedArray<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.values.append(value)
        }

        func snapshot() -> [Element] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    private final class SnapshotSequence: @unchecked Sendable {
        private let lock = NSLock()
        private let snapshots: [CursorStatusSnapshot]
        private var index = 0

        init(_ snapshots: [CursorStatusSnapshot]) {
            self.snapshots = snapshots
        }

        func next() -> CursorStatusSnapshot {
            self.lock.lock()
            defer { self.lock.unlock() }
            let snapshot = self.snapshots[min(self.index, self.snapshots.count - 1)]
            self.index += 1
            return snapshot
        }

        func count() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.index
        }
    }

    @Test
    func `add account opens Cursor auth URL in browser before polling cookies`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        var resolvedURLs: [URL] = []
        var phases: [String] = []
        var chooserCalls = 0

        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { route in
                launchedRoutes.append(route)
                return true
            },
            loadSnapshot: { Self.snapshot(email: "cursor@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: {
                resolvedURLs.append($0)
                return Self.cometApplicationURL
            },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { _ in
                chooserCalls += 1
                return nil
            },
            replaceSessionCache: { _ in true })

        #expect(resolvedURLs.isEmpty)

        let result = await runner.run { phase in
            switch phase {
            case .loading: phases.append("loading")
            case .waitingLogin: phases.append("waitingLogin")
            case .success: phases.append("success")
            case let .failed(message): phases.append("failed:\(message)")
            }
        }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.authURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(resolvedURLs == [CursorLoginRunner.authURL])
        #expect(phases == ["loading", "waitingLogin", "success"])
        #expect(chooserCalls == 0)
        #expect(result.email == "cursor@example.com")
    }

    @Test
    func `cancellation during browser selection does not launch the browser`() async {
        let launchedRoutes = LockedArray<CursorLoginBrowserRouter.Route>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { route in
                launchedRoutes.append(route)
                return true
            },
            loadSnapshot: {
                Issue.record("Cancelled login should not poll for an account")
                return Self.snapshot(email: "cursor@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: { loginURL, browserApplicationURL in
                withUnsafeCurrentTask { $0?.cancel() }
                return .route(CursorLoginBrowserRouter.Route(
                    launchURL: loginURL,
                    browserApplicationURL: browserApplicationURL ?? Self.cometApplicationURL))
            },
            replaceSessionCache: { _ in true })

        let result = await Task { await runner.run { _ in } }.value

        guard case .cancelled = result.outcome else {
            Issue.record("Expected cancellation before browser launch")
            return
        }
        #expect(launchedRoutes.snapshot().isEmpty)
    }

    @Test
    func `interactive login allows an explicit cookie retry in user initiated context`() async {
        var observedInteraction: ProviderInteraction?
        var retryAllowed = false
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { _ in true },
            loadSnapshot: { Self.snapshot(email: "cursor@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: { loginURL, browserApplicationURL in
                observedInteraction = ProviderInteractionContext.current
                retryAllowed = BrowserCookieAccessGate.shouldAttempt(.chrome)
                return .route(CursorLoginBrowserRouter.Route(
                    launchURL: loginURL,
                    browserApplicationURL: browserApplicationURL ?? Self.cometApplicationURL))
            },
            replaceSessionCache: { _ in true })

        let result = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.chrome]) {
                await runner.run { _ in }
            }
        }

        #expect(observedInteraction == .userInitiated)
        #expect(retryAllowed)
        guard case .success = result.outcome else {
            Issue.record("Expected a successful login")
            return
        }
    }

    @Test
    func `manual cookie identity allows the same browser account after confirmation`() async {
        let identity = ProviderIdentitySnapshot(
            providerID: .cursor,
            accountEmail: "same@example.com",
            accountOrganization: nil,
            loginMethod: "Pro",
            accountID: "same-account")
        let manualPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: .manual,
            identity: identity,
            hasPriorSnapshot: true)
        let automaticPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: .auto,
            identity: identity,
            hasPriorSnapshot: true)
        let unknownAutomaticPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: .auto,
            identity: nil,
            hasPriorSnapshot: true)
        let absentAutomaticPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: .auto,
            identity: nil,
            hasPriorSnapshot: false)
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: manualPolicy.priorAccount,
            requiresAccountConfirmation: manualPolicy.requiresConfirmation,
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { _ in true },
            loadSnapshot: { Self.snapshot(id: "same-account", email: "same@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return choices.first?.selectionID
            },
            replaceSessionCache: { _ in true })

        let result = await runner.run { _ in }

        #expect(manualPolicy.priorAccount == nil)
        #expect(manualPolicy.requiresConfirmation)
        #expect(automaticPolicy.priorAccount == .init(accountID: "same-account", email: "same@example.com"))
        #expect(automaticPolicy.requiresConfirmation)
        #expect(unknownAutomaticPolicy.priorAccount == .init(accountID: nil, email: nil))
        #expect(unknownAutomaticPolicy.requiresConfirmation)
        #expect(absentAutomaticPolicy.priorAccount == nil)
        #expect(!absentAutomaticPolicy.requiresConfirmation)
        #expect(presentedChoices.map(\.displayLabel) == ["same@example.com · Browser"])
        guard case .success = result.outcome else {
            Issue.record("Expected the same browser account to replace Manual mode")
            return
        }
    }

    @Test
    func `add account ignores identity-less snapshots`() async {
        let sequence = SnapshotSequence([
            Self.snapshot(email: nil),
            Self.snapshot(email: "cursor@example.com"),
        ])
        let runner = Self.runner(loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        #expect(sequence.count() == 2)
        #expect(result.email == "cursor@example.com")
    }

    @Test
    func `switch account opens Cursor auth URL and waits for a different normalized email`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        var resolvedURLs: [URL] = []
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let sequence = SnapshotSequence([
            Self.snapshot(email: "  CURRENT@example.com "),
            Self.snapshot(email: nil),
            Self.snapshot(email: "different@example.com"),
        ])
        let runner = Self.runner(
            priorAccount: .init(email: "current@example.com"),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            browserApplicationResolver: {
                resolvedURLs.append($0)
                return Self.cometApplicationURL
            },
            accountChooser: { choices in
                presentedChoices = choices
                return choices.first?.selectionID
            },
            loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.authURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(resolvedURLs == [CursorLoginRunner.authURL])
        #expect(sequence.count() == 3)
        #expect(presentedChoices.map(\.displayLabel) == ["different@example.com · Browser"])
        #expect(result.email == "different@example.com")
    }
}

extension CursorLoginRunnerTests {
    @Test
    func `switch account accepts the same email when stable account ID changes`() async {
        let committedHeaders = LockedArray<String>()
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: .init(accountID: " account-a ", email: " SAME@example.com "),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: "account-a",
                    email: "same@example.com",
                    cookieValue: "fixture-current",
                    source: "Work"),
                Self.browserCandidate(
                    id: "account-b",
                    email: "same@example.com",
                    cookieValue: "fixture-different",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return choices.first?.selectionID
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        let result = await runner.run { _ in }

        guard case .success = result.outcome else {
            Issue.record("Expected a successful switch")
            return
        }
        #expect(presentedChoices.map(\.displayLabel) == ["same@example.com · Personal"])
        #expect(committedHeaders.snapshot() == [Self.cursorCookieHeader("fixture-different")])
    }

    @Test
    func `switch account falls back to normalized email when stable IDs are absent`() async {
        let sequence = SnapshotSequence([
            Self.snapshot(id: nil, email: " CURRENT@example.com "),
            Self.snapshot(id: nil, email: "different@example.com"),
        ])
        let runner = Self.runner(
            priorAccount: .init(accountID: nil, email: "current@example.com"),
            accountChooser: { choices in choices.first?.selectionID },
            loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        #expect(sequence.count() == 2)
        #expect(result.email == "different@example.com")
    }

    @Test
    func `switch account cancellation with a sole candidate commits no session`() async {
        let committedHeaders = LockedArray<String>()
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: .init(email: "current@example.com"),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: "different-account",
                    email: "different@example.com",
                    cookieValue: "fixture-different",
                    source: "Comet"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return nil
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        let result = await runner.run { _ in }

        guard case .cancelled = result.outcome else {
            Issue.record("Expected account selection cancellation")
            return
        }
        #expect(presentedChoices.map(\.displayLabel) == ["different@example.com · Comet"])
        #expect(committedHeaders.snapshot().isEmpty)
    }

    @Test
    func `switch with unknown prior identity still requires candidate confirmation`() async {
        let committedHeaders = LockedArray<String>()
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: .init(email: nil),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: "candidate-account",
                    email: "candidate@example.com",
                    cookieValue: "fixture-candidate",
                    source: "Comet"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return nil
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        let result = await runner.run { _ in }

        guard case .cancelled = result.outcome else {
            Issue.record("Expected explicit candidate confirmation to remain cancellable")
            return
        }
        #expect(presentedChoices.map(\.displayLabel) == ["candidate@example.com · Comet"])
        #expect(committedHeaders.snapshot().isEmpty)
    }

    @Test
    func `switch account accepts a different stable ID with the same email`() async {
        let sequence = SnapshotSequence([
            Self.snapshot(id: "current-id", email: "same@example.com"),
            Self.snapshot(id: "next-id", email: "same@example.com"),
        ])
        let runner = Self.runner(
            priorAccount: .init(accountID: "current-id", email: "same@example.com"),
            accountChooser: { $0.first?.selectionID },
            loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        guard case .success = result.outcome else {
            Issue.record("Expected stable account ID change to complete the switch")
            return
        }
        #expect(sequence.count() == 2)
        #expect(result.email == "same@example.com")
    }

    @Test
    func `switch account accepts an ID only target`() async {
        let sequence = SnapshotSequence([
            Self.snapshot(id: "current-id", email: nil),
            Self.snapshot(id: "next-id", email: nil),
        ])
        let runner = Self.runner(
            priorAccount: .init(accountID: "current-id", email: nil),
            accountChooser: { $0.first?.selectionID },
            loadSnapshot: { sequence.next() })

        let result = await runner.run { _ in }

        guard case .success = result.outcome else {
            Issue.record("Expected ID-only account change to complete the switch")
            return
        }
        #expect(sequence.count() == 2)
        #expect(result.email == nil)
    }

    @Test
    func `Cursor usage identity preserves stable account ID`() {
        let usage = Self.snapshot(id: "stable-id", email: "cursor@example.com").toUsageSnapshot()

        #expect(usage.identity(for: .cursor)?.accountID == "stable-id")
    }

    @Test
    func `late cancellation still finalizes a committed login`() {
        let success = CursorLoginRunner.Result(outcome: .success, email: "cursor@example.com")
        let cancelled = CursorLoginRunner.Result(outcome: .cancelled, email: nil)

        #expect(StatusItemController.shouldFinalizeCursorLoginResult(success, taskIsCancelled: true))
        #expect(!StatusItemController.shouldFinalizeCursorLoginResult(cancelled, taskIsCancelled: true))
        #expect(StatusItemController.shouldFinalizeCursorLoginResult(cancelled, taskIsCancelled: false))
    }

    @Test
    func `switch timeout preserves existing session and explains that a different account is required`() async {
        let replacementEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: .init(email: "current@example.com"),
            timeout: 0,
            pollInterval: 0.01,
            launchRoute: { _ in true },
            loadSnapshot: { Self.snapshot(email: "current@example.com") },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            replaceSessionCache: { _ in
                replacementEvents.append("replace")
                return true
            })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(message.contains("different Cursor account"))
        #expect(replacementEvents.snapshot().isEmpty)
    }

    @Test
    func `accepted login replaces stale session after selecting candidate`() async {
        let events = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { _ in
                events.append("open")
                return true
            },
            loadBrowserLoginCandidates: { _, _ in
                events.append("poll")
                return [Self.browserCandidate(
                    id: "accepted-account",
                    email: "cursor@example.com",
                    cookieValue: "fixture-accepted",
                    source: "Comet")]
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            replaceSessionCache: { _ in
                events.append("replace")
                return true
            })

        _ = await runner.run { _ in }

        #expect(events.snapshot() == ["open", "poll", "replace"])
    }

    @Test
    func `accepted login reports failure when the replacement is not durable`() async {
        var phases: [String] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: "accepted-account",
                    email: "cursor@example.com",
                    cookieValue: "fixture-accepted",
                    source: "Comet"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            replaceSessionCache: { _ in false })

        let result = await runner.run { phase in
            switch phase {
            case .loading: phases.append("loading")
            case .waitingLogin: phases.append("waitingLogin")
            case .success: phases.append("success")
            case .failed: phases.append("failed")
            }
        }

        guard case .failed = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(result.email == nil)
        #expect(phases == ["loading", "waitingLogin", "failed"])
    }

    @Test
    func `login launch failure preserves existing session`() async {
        let replacementEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: { _ in false },
            loadSnapshot: {
                Issue.record("Should not poll cookies when browser launch fails")
                throw CursorStatusProbeError.noSessionCookie
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            replaceSessionCache: { _ in
                replacementEvents.append("replace")
                return true
            })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(message.contains("Could not open Cursor login"))
        #expect(replacementEvents.snapshot().isEmpty)
    }

    @Test
    func `login cancellation while waiting preserves existing session`() async {
        let events = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 10,
            pollInterval: 0.01,
            launchRoute: { _ in
                events.append("open")
                return true
            },
            loadBrowserLoginCandidates: { _, _ in
                events.append("poll")
                return []
            },
            sleeper: { _ in
                events.append("sleep")
                try await Task.sleep(nanoseconds: .max)
            },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            replaceSessionCache: { _ in
                events.append("replace")
                return true
            })

        let task = Task {
            await runner.run { _ in }
        }
        while !events.snapshot().contains("sleep") {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value

        guard case .cancelled = result.outcome else {
            Issue.record("Expected cancelled outcome")
            return
        }
        #expect(!events.snapshot().contains("replace"))
    }

    @Test
    func `unsupported default browser fails before opening or polling`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let pollEvents = LockedArray<String>()
        let replacementEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadSnapshot: {
                pollEvents.append("poll")
                return Self.snapshot(email: "wrong@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Unsupported Browser.app")
            },
            routeResolver: { _, _ in .unavailable },
            replaceSessionCache: { _ in
                replacementEvents.append("replace")
                return true
            })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected unsupported-browser failure")
            return
        }
        #expect(message.contains("Unsupported Browser"))
        #expect(message.contains("Cookie header"))
        #expect(launchedRoutes.isEmpty)
        #expect(pollEvents.snapshot().isEmpty)
        #expect(replacementEvents.snapshot().isEmpty)
    }

    @Test
    func `unresolved default browser fails before opening or polling`() async {
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let pollEvents = LockedArray<String>()
        let replacementEvents = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadSnapshot: {
                pollEvents.append("poll")
                return Self.snapshot(email: "wrong@example.com")
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in nil },
            routeResolver: { _, _ in .unavailable },
            replaceSessionCache: { _ in
                replacementEvents.append("replace")
                return true
            })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected unresolved-browser failure")
            return
        }
        #expect(message.contains("Browser cookies"))
        #expect(message.contains("Cookie header"))
        #expect(launchedRoutes.isEmpty)
        #expect(pollEvents.snapshot().isEmpty)
        #expect(replacementEvents.snapshot().isEmpty)
    }

    @Test
    func `browser chooser cancellation happens before replacement launch and polling`() async {
        let events = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            launchRoute: { _ in
                events.append("launch")
                return true
            },
            loadSnapshot: {
                events.append("poll")
                return Self.snapshot(email: "unexpected@example.com")
            },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Link Router.app")
            },
            routeResolver: { _, _ in .cancelled },
            replaceSessionCache: { _ in
                events.append("replace")
                return true
            })

        let result = await runner.run { _ in }

        guard case .cancelled = result.outcome else {
            Issue.record("Expected browser selection cancellation")
            return
        }
        #expect(events.snapshot().isEmpty)
    }

    @Test
    func `production candidate loader receives the exact pinned browser URL`() async {
        let loadedBrowserURLs = LockedArray<URL>()
        let candidateTimeouts = LockedArray<TimeInterval>()
        var launchedRoutes: [CursorLoginBrowserRouter.Route] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: {
                launchedRoutes.append($0)
                return true
            },
            loadBrowserLoginCandidates: { browserApplicationURL, timeout in
                loadedBrowserURLs.append(browserApplicationURL)
                candidateTimeouts.append(timeout)
                return [Self.browserCandidate(
                    id: "account",
                    email: "cursor@example.com",
                    cookieValue: "fixture-single",
                    source: "Comet")]
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in
                URL(fileURLWithPath: "/Applications/Link Router.app")
            },
            routeResolver: { _, _ in
                .route(.init(
                    launchURL: URL(string: "https://example.invalid/intermediary")!,
                    browserApplicationURL: Self.cometApplicationURL))
            },
            replaceSessionCache: { _ in true })

        _ = await runner.run { _ in }

        #expect(launchedRoutes.map(\.launchURL) == [CursorLoginRunner.authURL])
        #expect(launchedRoutes.map(\.browserApplicationURL) == [Self.cometApplicationURL])
        #expect(loadedBrowserURLs.snapshot() == [Self.cometApplicationURL])
        let passedTimeout = candidateTimeouts.snapshot().first
        #expect(passedTimeout.map { $0 > 0 && $0 <= 1 } == true)
    }

    @Test
    func `account chooser cancel and forged result commit no session`() async {
        for chosenID in [String?.none, "forged-selection"] {
            let committedHeaders = LockedArray<String>()
            var presentedChoices: [CursorLoginAccountSelector.Choice] = []
            let runner = CursorLoginRunner(
                browserDetection: BrowserDetection(cacheTTL: 0),
                timeout: 1,
                pollInterval: 0.001,
                launchRoute: { _ in true },
                loadBrowserLoginCandidates: { _, _ in [
                    Self.browserCandidate(
                        id: "account-a",
                        email: "a@example.com",
                        cookieValue: "fixture-a",
                        source: "Work"),
                    Self.browserCandidate(
                        id: "account-b",
                        email: "b@example.com",
                        cookieValue: "fixture-b",
                        source: "Personal"),
                ] },
                sleeper: { _ in },
                browserApplicationResolver: { _ in Self.cometApplicationURL },
                routeResolver: Self.fixtureRouteResolver,
                accountChooser: { choices in
                    presentedChoices = choices
                    return chosenID
                },
                replaceSessionCache: { session in
                    committedHeaders.append(session.cookieHeader)
                    return true
                })

            let result = await runner.run { _ in }

            guard case .cancelled = result.outcome else {
                Issue.record("Expected account selection cancellation")
                continue
            }
            #expect(presentedChoices.count == 2)
            #expect(Set(presentedChoices.map(\.selectionID)) == [
                "cursor-candidate-0",
                "cursor-candidate-1",
            ])
            #expect(committedHeaders.snapshot().isEmpty)
        }
    }

    @Test
    func `account candidates dedupe by stable ID and preserve distinct IDs with the same email`() async {
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: " account-a ",
                    email: "same@example.com",
                    cookieValue: "fixture-first-a",
                    source: "Work"),
                Self.browserCandidate(
                    id: "account-a",
                    email: "other@example.com",
                    cookieValue: "fixture-duplicate-a",
                    source: "Work Network"),
                Self.browserCandidate(
                    id: "account-b",
                    email: "same@example.com",
                    cookieValue: "fixture-b",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { choices in
                presentedChoices = choices
                return choices.first(where: { $0.displayLabel.contains("Personal") })?.selectionID
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        _ = await runner.run { _ in }

        #expect(presentedChoices.count == 2)
        #expect(committedHeaders.snapshot() == [Self.cursorCookieHeader("fixture-b")])
    }

    @Test
    func `account candidates use normalized email only when stable ID is absent`() async {
        var chooserCalls = 0
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: nil,
                    email: " SAME@example.com ",
                    cookieValue: "fixture-first",
                    source: "Work"),
                Self.browserCandidate(
                    id: nil,
                    email: "same@example.com",
                    cookieValue: "fixture-second",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { _ in
                chooserCalls += 1
                return nil
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        _ = await runner.run { _ in }

        #expect(chooserCalls == 0)
        #expect(committedHeaders.snapshot() == [Self.cursorCookieHeader("fixture-first")])
    }

    @Test
    func `identified candidate replaces an earlier email only candidate`() async {
        var chooserCalls = 0
        let committedHeaders = LockedArray<String>()
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: { _ in true },
            loadBrowserLoginCandidates: { _, _ in [
                Self.browserCandidate(
                    id: nil,
                    email: "same@example.com",
                    cookieValue: "fixture-email-only",
                    source: "Work"),
                Self.browserCandidate(
                    id: "stable-account",
                    email: " SAME@example.com ",
                    cookieValue: "fixture-identified",
                    source: "Personal"),
            ] },
            sleeper: { _ in },
            browserApplicationResolver: { _ in Self.cometApplicationURL },
            routeResolver: Self.fixtureRouteResolver,
            accountChooser: { _ in
                chooserCalls += 1
                return nil
            },
            replaceSessionCache: { session in
                committedHeaders.append(session.cookieHeader)
                return true
            })

        _ = await runner.run { _ in }

        #expect(chooserCalls == 0)
        #expect(committedHeaders.snapshot() == [Self.cursorCookieHeader("fixture-identified")])
    }

    private static func runner(
        priorAccount: CursorLoginRunner.AccountIdentity? = nil,
        launchRoute: @escaping CursorLoginRunner.RouteLauncher = { _ in true },
        browserApplicationResolver: @escaping CursorLoginRunner.BrowserApplicationResolver = { _ in
            Self.cometApplicationURL
        },
        accountChooser: CursorLoginRunner.AccountChooser? = nil,
        loadSnapshot: @escaping CursorLoginRunner.SnapshotLoader) -> CursorLoginRunner
    {
        CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            priorAccount: priorAccount,
            timeout: 1,
            pollInterval: 0.001,
            launchRoute: launchRoute,
            loadSnapshot: loadSnapshot,
            sleeper: { _ in },
            browserApplicationResolver: browserApplicationResolver,
            routeResolver: self.fixtureRouteResolver,
            accountChooser: accountChooser,
            replaceSessionCache: { _ in true })
    }

    private static func fixtureRouteResolver(
        loginURL: URL,
        handlerApplicationURL: URL?) -> CursorLoginBrowserRouter.Resolution
    {
        guard let handlerApplicationURL else { return .unavailable }
        return .route(.init(
            launchURL: loginURL,
            browserApplicationURL: handlerApplicationURL))
    }

    private nonisolated static func snapshot(id: String? = nil, email: String?) -> CursorStatusSnapshot {
        CursorStatusSnapshot(
            planPercentUsed: 12,
            planUsedUSD: 1,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: email,
            accountID: id,
            accountName: nil,
            rawJSON: nil)
    }

    private nonisolated static func browserCandidate(
        id: String?,
        email: String?,
        cookieValue: String,
        source: String) -> CursorStatusProbe.BrowserLoginResult
    {
        CursorStatusProbe.BrowserLoginResult(
            snapshot: self.snapshot(id: id, email: email),
            session: .init(
                cookieHeader: self.cursorCookieHeader(cookieValue),
                sourceLabel: source))
    }

    private nonisolated static func cursorCookieHeader(_ value: String) -> String {
        ["WorkosCursorSessionToken", value].joined(separator: "=")
    }
}
