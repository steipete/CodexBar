import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class OpenCodeGoZenBalanceTaskRace: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceTask: Task<Double?, Error>
    private var result: Result<Double?, Error>?
    private var continuation: CheckedContinuation<Double?, Error>?
    private var observerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(sourceTask: Task<Double?, Error>) {
        self.sourceTask = sourceTask
    }

    func value(timeout: Duration? = nil) async throws -> Double? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(with: result)
                    return
                }

                self.continuation = continuation
                let sourceTask = self.sourceTask
                self.observerTask = Task { [weak self] in
                    do {
                        let value = try await sourceTask.value
                        self?.resolve(.success(value), cancelSource: false)
                    } catch {
                        self?.resolve(.failure(error), cancelSource: false)
                    }
                }
                if let timeout {
                    self.timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                            self?.resolve(.success(nil), cancelSource: true)
                        } catch {
                            // The source completed or the caller canceled the race.
                        }
                    }
                }
                self.lock.unlock()
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()), cancelSource: true)
        }
    }

    private func resolve(_ result: Result<Double?, Error>, cancelSource: Bool) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }

        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let observerTask = self.observerTask
        let timeoutTask = self.timeoutTask
        self.observerTask = nil
        self.timeoutTask = nil
        self.lock.unlock()

        if cancelSource {
            self.sourceTask.cancel()
        }
        observerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

extension OpenCodeGoUsageFetcher {
    static let optionalZenBalanceTimeout: TimeInterval = 5
    static let optionalZenBalanceStartDelay: Duration = .milliseconds(25)
    static let optionalZenBalanceJoinGrace: Duration = .milliseconds(250)

    public static func zenDashboardURL(workspaceID raw: String?) -> URL {
        guard let workspaceID = self.normalizeWorkspaceID(raw),
              let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)")
        else {
            return URL(string: "https://opencode.ai")!
        }
        return url
    }

    static func fetchOptionalZenBalance(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> Double?
    {
        do {
            let balance = try await self.fetchZenBalance(
                workspaceID: workspaceID,
                cookieHeader: cookieHeader,
                timeout: timeout,
                session: session)
            try Task.checkCancellation()
            return balance
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    static func completedOptionalZenBalance(from task: Task<Double?, Error>) async throws -> Double? {
        let race = OpenCodeGoZenBalanceTaskRace(sourceTask: task)
        do {
            return try await race.value(timeout: self.optionalZenBalanceJoinGrace)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func completedRequiredZenBalance(from task: Task<Double?, Error>) async throws -> Double? {
        let race = OpenCodeGoZenBalanceTaskRace(sourceTask: task)
        return try await race.value()
    }

    static func parseZenBalance(text: String) -> Double? {
        OpenCodeGoZenBalanceParser.parse(text: text)
    }

    static func fetchZenBalance(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> Double?
    {
        let text = try await self.fetchPageText(
            url: self.zenDashboardURL(workspaceID: workspaceID),
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        if self.looksSignedOut(text: text) {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        if let balance = self.parseZenBalance(text: text) {
            return balance
        }

        let billingText = try await self.fetchZenBillingText(
            workspaceID: workspaceID,
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        if self.looksSignedOut(text: billingText) {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        return OpenCodeGoZenBalanceParser.parseBillingServerResponse(text: billingText)
    }
}
