import AppKit
import CodexBarCore
import Foundation

private func normalizedCursorAccountID(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func normalizedCursorAccountEmail(_ value: String?) -> String? {
    guard let value = value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
        !value.isEmpty
    else {
        return nil
    }
    return value
}

/// Opens Cursor in a concrete browser and waits until that browser's cookie store exposes a session.
@MainActor
final class CursorLoginRunner {
    struct AccountIdentity: Equatable, Sendable {
        let accountID: String?
        let email: String?

        init(accountID: String? = nil, email: String?) {
            self.accountID = accountID
            self.email = email
        }

        fileprivate var hasIdentity: Bool {
            normalizedCursorAccountID(self.accountID) != nil ||
                normalizedCursorAccountEmail(self.email) != nil
        }
    }

    struct AccountPolicy: Equatable, Sendable {
        let priorAccount: AccountIdentity?
        let requiresConfirmation: Bool
    }

    static func accountPolicy(
        configuredSource: ProviderCookieSource,
        identity: ProviderIdentitySnapshot?,
        hasPriorSnapshot: Bool) -> AccountPolicy
    {
        guard hasPriorSnapshot else {
            return AccountPolicy(priorAccount: nil, requiresConfirmation: false)
        }
        let account = AccountIdentity(accountID: identity?.accountID, email: identity?.accountEmail)
        return AccountPolicy(
            priorAccount: configuredSource == .auto ? account : nil,
            requiresConfirmation: true)
    }

    enum Phase {
        case loading
        case waitingLogin
        case success
        case failed(String)
    }

    struct Result {
        enum Outcome {
            case success
            case cancelled
            case failed(String)
        }

        let outcome: Outcome
        let email: String?
    }

    struct SnapshotLoadResult: Sendable {
        let snapshot: CursorStatusSnapshot
        let session: CursorStatusProbe.BrowserLoginSession?
        let sourceLabel: String?

        init(
            snapshot: CursorStatusSnapshot,
            session: CursorStatusProbe.BrowserLoginSession?,
            sourceLabel: String? = nil)
        {
            self.snapshot = snapshot
            self.session = session
            self.sourceLabel = sourceLabel
        }
    }

    typealias SnapshotLoader = @Sendable () async throws -> CursorStatusSnapshot
    typealias BrowserLoginCandidatesLoader = @Sendable (URL, TimeInterval) async throws
        -> [CursorStatusProbe.BrowserLoginResult]
    typealias Sleeper = @Sendable (UInt64) async throws -> Void
    typealias SessionCacheReplacer = @MainActor @Sendable (CursorStatusProbe.BrowserLoginSession) async -> Bool
    typealias RouteLauncher = @MainActor (CursorLoginBrowserRouter.Route) async -> Bool
    typealias BrowserApplicationResolver = @MainActor (URL) -> URL?
    typealias RouteResolver = @MainActor (URL, URL?) -> CursorLoginBrowserRouter.Resolution
    typealias AccountChooser = CursorLoginAccountSelector.Chooser

    private enum CandidateSelection {
        case none
        case selected(SnapshotLoadResult)
        case cancelled
    }

    private enum RoutePreparation {
        case ready(CursorLoginBrowserRouter.Route)
        case terminal(Result)
    }

    private let loadBrowserLoginCandidates: @Sendable (URL, TimeInterval) async throws -> [SnapshotLoadResult]
    private let launchRoute: RouteLauncher
    private let sleeper: Sleeper
    private let replaceSessionCache: SessionCacheReplacer
    private let priorAccount: AccountIdentity?
    private let requiresAccountConfirmation: Bool
    private let browserApplicationResolver: BrowserApplicationResolver
    private let routeResolver: RouteResolver
    private let accountChooser: AccountChooser?
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let logger = CodexBarLog.logger(LogCategories.cursorLogin)

    static let authURL = URL(string: "https://authenticator.cursor.sh/")!

    init(
        browserDetection: BrowserDetection,
        priorAccount: AccountIdentity? = nil,
        requiresAccountConfirmation: Bool? = nil,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2,
        launchRoute: @escaping RouteLauncher = { route in await CursorLoginRunner.launch(route) },
        loadSnapshot: SnapshotLoader? = nil,
        loadBrowserLoginCandidates: BrowserLoginCandidatesLoader? = nil,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
        browserApplicationResolver: @escaping BrowserApplicationResolver = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)
        },
        routeResolver: RouteResolver? = nil,
        accountChooser: AccountChooser? = nil,
        replaceSessionCache: @escaping SessionCacheReplacer = { session in
            await CursorLoginRunner.replaceCachedSession(session)
        })
    {
        self.priorAccount = priorAccount
        self.requiresAccountConfirmation = requiresAccountConfirmation ?? (priorAccount != nil)
        self.browserApplicationResolver = browserApplicationResolver
        self.routeResolver = routeResolver ?? { loginURL, handlerApplicationURL in
            CursorLoginBrowserRouter.resolve(
                loginURL: loginURL,
                handlerApplicationURL: handlerApplicationURL,
                supportsBrowser: { applicationURL in
                    CursorStatusProbe.supportsInteractiveLoginBrowser(
                        applicationURL: applicationURL,
                        browserDetection: browserDetection)
                })
        }
        self.accountChooser = accountChooser
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.launchRoute = launchRoute
        self.sleeper = sleeper
        self.replaceSessionCache = replaceSessionCache
        if let loadBrowserLoginCandidates {
            self.loadBrowserLoginCandidates = { browserApplicationURL, timeout in
                try await loadBrowserLoginCandidates(browserApplicationURL, timeout).map { result in
                    SnapshotLoadResult(
                        snapshot: result.snapshot,
                        session: result.session,
                        sourceLabel: result.sourceLabel)
                }
            }
        } else if let loadSnapshot {
            self.loadBrowserLoginCandidates = { _, _ in
                let snapshot = try await loadSnapshot()
                return [SnapshotLoadResult(snapshot: snapshot, session: nil)]
            }
        } else {
            self.loadBrowserLoginCandidates = { browserApplicationURL, timeout in
                let probe = CursorStatusProbe(browserDetection: browserDetection)
                return try await probe.fetchBrowserLoginCandidates(
                    browserApplicationURL: browserApplicationURL,
                    timeout: timeout).map { result in
                    SnapshotLoadResult(
                        snapshot: result.snapshot,
                        session: result.session,
                        sourceLabel: result.sourceLabel)
                }
            }
        }
    }

    func run(onPhaseChange: @escaping @MainActor (Phase) -> Void) async -> Result {
        await BrowserCookieAccessGate.withExplicitRetry {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.runUserInitiated(onPhaseChange: onPhaseChange)
            }
        }
    }

    private func runUserInitiated(onPhaseChange: @escaping @MainActor (Phase) -> Void) async -> Result {
        onPhaseChange(.loading)
        self.logger.info("Cursor login started")
        guard !Task.isCancelled else {
            self.logger.info("Cursor login cancelled before cache ownership")
            return Result(outcome: .cancelled, email: nil)
        }

        let cacheMutationGate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)
        defer { CookieHeaderCache.endConditionalMutationGate(cacheMutationGate) }

        let route: CursorLoginBrowserRouter.Route
        switch self.prepareRoute(onPhaseChange: onPhaseChange) {
        case let .ready(preparedRoute):
            route = preparedRoute
        case let .terminal(result):
            return result
        }

        guard !Task.isCancelled else {
            return self.cancelAfterTaskCancellation()
        }
        let launched = await self.launchRoute(route)
        guard !Task.isCancelled else {
            return self.cancelAfterTaskCancellation()
        }
        guard launched else {
            let message = L("Could not open Cursor login in your browser.")
            onPhaseChange(.failed(message))
            self.logger.error("Cursor login browser launch failed")
            return Result(outcome: .failed(message), email: nil)
        }

        onPhaseChange(.waitingLogin)
        let deadline = Date().addingTimeInterval(self.timeout)
        var lastError: Error?

        repeat {
            if let cancellation = self.continuationCancellationResult() {
                return cancellation
            }

            do {
                let remainingTime = deadline.timeIntervalSinceNow
                guard remainingTime > 0 else { break }
                let loaded = try await self.loadBrowserLoginCandidates(
                    route.browserApplicationURL,
                    remainingTime)
                if let cancellation = self.continuationCancellationResult() {
                    return cancellation
                }
                if let result = await self.completeLoadedCandidates(
                    loaded,
                    onPhaseChange: onPhaseChange)
                {
                    return result
                }
            } catch {
                if Task.isCancelled {
                    return self.cancelAfterTaskCancellation()
                }
                lastError = error
            }
            guard Date() < deadline else { break }
            let delay = UInt64(max(0.1, self.pollInterval) * 1_000_000_000)
            try? await self.sleeper(delay)
        } while true

        if Task.isCancelled {
            return self.cancelAfterTaskCancellation()
        }
        let message = self.timeoutMessage(lastError: lastError)
        onPhaseChange(.failed(message))
        self.logger.warning("Cursor login timed out", metadata: ["error": message])
        return Result(outcome: .failed(message), email: nil)
    }

    private func continuationCancellationResult() -> Result? {
        guard !Task.isCancelled else {
            return self.cancelAfterTaskCancellation()
        }
        return nil
    }

    private func prepareRoute(onPhaseChange: @MainActor (Phase) -> Void) -> RoutePreparation {
        let loginURL = Self.authURL
        let handlerApplicationURL = self.browserApplicationResolver(loginURL)
        let route: CursorLoginBrowserRouter.Route

        switch self.routeResolver(loginURL, handlerApplicationURL) {
        case let .route(resolvedRoute):
            route = CursorLoginBrowserRouter.Route(
                launchURL: loginURL,
                browserApplicationURL: resolvedRoute.browserApplicationURL)
        case .cancelled:
            self.logger.info("Cursor login browser selection cancelled")
            return .terminal(Result(outcome: .cancelled, email: nil))
        case .unavailable:
            let message = Self.unsupportedBrowserMessage(applicationURL: handlerApplicationURL)
            onPhaseChange(.failed(message))
            self.logger.error("Cursor login browser unavailable", metadata: ["error": message])
            return .terminal(Result(outcome: .failed(message), email: nil))
        }

        return .ready(route)
    }

    private func completeLoadedCandidates(
        _ loaded: [SnapshotLoadResult],
        onPhaseChange: @MainActor (Phase) -> Void) async -> Result?
    {
        switch self.selectCandidate(from: loaded) {
        case .none:
            return nil
        case .cancelled:
            self.logger.info("Cursor login account selection cancelled")
            return Result(outcome: .cancelled, email: nil)
        case let .selected(candidate):
            guard !Task.isCancelled else {
                return self.cancelAfterTaskCancellation()
            }
            return await self.completeAcceptedLogin(
                candidate,
                onPhaseChange: onPhaseChange)
        }
    }

    private func selectCandidate(from loaded: [SnapshotLoadResult]) -> CandidateSelection {
        let candidates = self.deduplicatedCandidates(from: loaded)

        guard !candidates.isEmpty else { return .none }
        // A sole Add candidate is unambiguous.
        // Switching still needs confirmation because browser profiles can be stale.
        guard self.requiresAccountConfirmation || candidates.count > 1 else {
            return .selected(candidates[0])
        }

        let presentedCandidates = candidates.enumerated().map { index, candidate in
            CursorLoginAccountSelector.Candidate(
                selectionID: "cursor-candidate-\(index)",
                name: candidate.snapshot.accountName,
                email: candidate.snapshot.accountEmail,
                sourceLabel: candidate.sourceLabel ?? L("Browser"))
        }
        let selectedID: String? = if let accountChooser {
            CursorLoginAccountSelector.selectCandidateID(
                from: presentedCandidates,
                chooser: accountChooser)
        } else {
            CursorLoginAccountSelector.selectCandidateID(from: presentedCandidates)
        }
        guard let selectedID,
              let selectedIndex = presentedCandidates.firstIndex(where: { $0.selectionID == selectedID })
        else {
            return .cancelled
        }
        return .selected(candidates[selectedIndex])
    }

    private func deduplicatedCandidates(from loaded: [SnapshotLoadResult]) -> [SnapshotLoadResult] {
        var candidates: [SnapshotLoadResult] = []

        for candidate in loaded where Self.isAcceptableAccount(candidate.snapshot, priorAccount: self.priorAccount) {
            let accountID = normalizedCursorAccountID(candidate.snapshot.accountID)
            let email = normalizedCursorAccountEmail(candidate.snapshot.accountEmail)

            if let accountID {
                if candidates.contains(where: {
                    normalizedCursorAccountID($0.snapshot.accountID) == accountID
                }) {
                    continue
                }
                if let email,
                   let emailOnlyIndex = candidates.firstIndex(where: {
                       normalizedCursorAccountID($0.snapshot.accountID) == nil &&
                           normalizedCursorAccountEmail($0.snapshot.accountEmail) == email
                   })
                {
                    candidates[emailOnlyIndex] = candidate
                } else {
                    candidates.append(candidate)
                }
                continue
            }

            guard let email else { continue }
            if candidates.contains(where: {
                normalizedCursorAccountEmail($0.snapshot.accountEmail) == email
            }) {
                continue
            }
            candidates.append(candidate)
        }

        return candidates
    }

    private func completeAcceptedLogin(
        _ loaded: SnapshotLoadResult,
        onPhaseChange: @MainActor (Phase) -> Void) async -> Result
    {
        let snapshot = loaded.snapshot
        if let session = loaded.session {
            guard await self.replaceSessionCache(session) else {
                let message = L("Cursor login failed")
                onPhaseChange(.failed(message))
                self.logger.error("Cursor login session cache commit failed")
                return Result(outcome: .failed(message), email: nil)
            }
        }
        onPhaseChange(.success)
        self.logger.info("Cursor login completed", metadata: ["outcome": "success"])
        return Result(outcome: .success, email: snapshot.accountEmail)
    }

    private func cancelAfterTaskCancellation() -> Result {
        self.logger.info("Cursor login cancelled")
        return Result(outcome: .cancelled, email: nil)
    }

    @MainActor
    static func replaceCachedSession(
        _ session: CursorStatusProbe.BrowserLoginSession,
        afterCommit: @MainActor () -> Void = {}) async -> Bool
    {
        // Candidate discovery is cache-independent. Keep both active stores intact until the replacement is durable.
        guard CursorStatusProbe.commitBrowserLoginSession(session) else { return false }
        afterCommit()
        await CursorSessionStore.shared.clearCookies()
        return true
    }

    private static func launch(_ route: CursorLoginBrowserRouter.Route) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                [route.launchURL],
                withApplicationAt: route.browserApplicationURL,
                configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func isAcceptableAccount(
        _ snapshot: CursorStatusSnapshot,
        priorAccount: AccountIdentity?) -> Bool
    {
        guard let priorAccount else {
            return normalizedCursorAccountID(snapshot.accountID) != nil ||
                normalizedCursorAccountEmail(snapshot.accountEmail) != nil
        }

        guard priorAccount.hasIdentity else {
            // Preserve Switch intent when the current usage response lacks identity metadata. The candidate still
            // requires explicit confirmation because `selectCandidate` sees a non-nil prior account.
            return normalizedCursorAccountID(snapshot.accountID) != nil ||
                normalizedCursorAccountEmail(snapshot.accountEmail) != nil
        }

        if let priorAccountID = normalizedCursorAccountID(priorAccount.accountID),
           let candidateAccountID = normalizedCursorAccountID(snapshot.accountID)
        {
            return candidateAccountID != priorAccountID
        }

        guard let priorEmail = normalizedCursorAccountEmail(priorAccount.email),
              let candidateEmail = normalizedCursorAccountEmail(snapshot.accountEmail)
        else { return false }
        return candidateEmail != priorEmail
    }

    private func timeoutMessage(lastError: Error?) -> String {
        if self.priorAccount != nil {
            let hint = L("Finish switching to a different Cursor account in your browser, then try again.")
            guard let lastError else {
                return String(format: L("Timed out waiting for Cursor account switch. %@"), hint)
            }
            return String(
                format: L("Timed out waiting for Cursor account switch. %@ Last error: %@"),
                hint,
                lastError.localizedDescription)
        }

        let hint = L("Sign in to cursor.com in your browser, then refresh Cursor in CodexBar.")
        guard let lastError else {
            return String(format: L("Timed out waiting for Cursor login. %@"), hint)
        }
        return String(
            format: L("Timed out waiting for Cursor login. %@ Last error: %@"),
            hint,
            lastError.localizedDescription)
    }

    private static func unsupportedBrowserMessage(applicationURL: URL?) -> String {
        let headline = L("Could not open Cursor login in your browser.")
        let manualFallback = String(
            format: L("Paste a Cookie header from %@."),
            "cursor.com")
        guard let applicationURL else {
            return "\(headline) \(L("Browser cookies")): \(L("Unsupported")). \(manualFallback)"
        }
        let applicationName = applicationURL.deletingPathExtension().lastPathComponent
        let unsupported = String(format: L("%@: unsupported"), applicationName)
        return "\(headline) \(unsupported). \(manualFallback)"
    }
}
