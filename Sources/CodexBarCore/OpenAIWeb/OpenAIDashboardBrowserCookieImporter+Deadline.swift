#if os(macOS)
import Foundation

extension OpenAIDashboardBrowserCookieImporter {
    /// GCD timer blocks can be delayed with the work they are supposed to bound when its pool is saturated.
    private final class DeadlineScheduler: @unchecked Sendable {
        private struct Entry {
            let deadline: Date
            let action: @Sendable () -> Void
        }

        private let condition = NSCondition()
        private var entries: [Entry] = []

        init() {
            let thread = Thread { [weak self] in
                self?.run()
            }
            thread.name = "com.steipete.codexbar.openai-cookie-deadline"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func schedule(after timeout: TimeInterval, action: @escaping @Sendable () -> Void) {
            let entry = Entry(deadline: Date().addingTimeInterval(timeout), action: action)
            self.condition.lock()
            let insertionIndex = self.entries.firstIndex { entry.deadline < $0.deadline } ?? self.entries.endIndex
            self.entries.insert(entry, at: insertionIndex)
            self.condition.signal()
            self.condition.unlock()
        }

        private func run() {
            while true {
                self.condition.lock()
                while self.entries.isEmpty {
                    self.condition.wait()
                }

                guard let entry = self.entries.first else {
                    self.condition.unlock()
                    continue
                }
                if entry.deadline.timeIntervalSinceNow > 0 {
                    self.condition.wait(until: entry.deadline)
                    self.condition.unlock()
                    continue
                }

                self.entries.removeFirst()
                self.condition.unlock()
                autoreleasepool {
                    entry.action()
                }
            }
        }
    }

    private struct PendingCookieStoreMutation {
        let token: UUID
        let task: Task<Void, Never>
    }

    @MainActor private static var pendingCookieStoreMutations: [ObjectIdentifier: PendingCookieStoreMutation] = [:]
    private nonisolated static let cookieCacheQueue = DispatchQueue(
        label: "com.steipete.codexbar.openai-cookie-cache")
    private nonisolated static let deadlineScheduler = DeadlineScheduler()

    private final class CookieLoadCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false

        func finish(_ action: () -> Void) {
            let shouldFinish = self.lock.withLock {
                guard !self.didFinish else { return false }
                self.didFinish = true
                return true
            }
            if shouldFinish { action() }
        }
    }

    nonisolated static func remainingTimeout(
        until deadline: Date?,
        cappedAt localLimit: TimeInterval? = nil,
        now: Date = Date()) throws -> TimeInterval
    {
        guard let deadline else {
            return localLimit.map(OpenAIDashboardFetcher.sanitizedTimeout) ?? .greatestFiniteMagnitude
        }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { throw URLError(.timedOut) }
        guard let localLimit else { return remaining }
        return min(OpenAIDashboardFetcher.sanitizedTimeout(localLimit), remaining)
    }

    nonisolated static func runBoundedCookieLoad<T: Sendable>(
        deadline: Date?,
        operation: @escaping @Sendable () throws -> T) async throws -> T
    {
        guard let deadline else {
            return try await Task.detached(priority: .userInitiated, operation: operation).value
        }
        let timeout = try self.remainingTimeout(until: deadline)
        let completion = CookieLoadCompletion()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result(catching: operation)
                completion.finish { continuation.resume(with: result) }
            }
            self.deadlineScheduler.schedule(after: timeout) {
                completion.finish { continuation.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    nonisolated static func runBoundedCookieCacheOperation<T: Sendable>(
        deadline: Date?,
        operation: @escaping @Sendable () throws -> T) async throws -> T
    {
        try await self.runBoundedCookieLoad(deadline: deadline) {
            try self.cookieCacheQueue.sync(execute: operation)
        }
    }

    static func runBoundedCallback(
        deadline: Date?,
        start: (@escaping @Sendable () -> Void) -> Void) async throws
    {
        let completion = CookieLoadCompletion()
        guard let deadline else {
            await withCheckedContinuation { continuation in
                start {
                    completion.finish { continuation.resume() }
                }
            }
            return
        }

        let timeout = try self.remainingTimeout(until: deadline)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            start {
                completion.finish { continuation.resume() }
            }
            self.deadlineScheduler.schedule(after: timeout) {
                completion.finish { continuation.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    static func runBoundedValueCallback<T: Sendable>(
        deadline: Date?,
        start: (@escaping @Sendable (T) -> Void) -> Void) async throws -> T
    {
        let completion = CookieLoadCompletion()
        guard let deadline else {
            return await withCheckedContinuation { continuation in
                start { value in
                    completion.finish { continuation.resume(returning: value) }
                }
            }
        }

        let timeout = try self.remainingTimeout(until: deadline)
        return try await withCheckedThrowingContinuation { continuation in
            start { value in
                completion.finish { continuation.resume(returning: value) }
            }
            self.deadlineScheduler.schedule(after: timeout) {
                completion.finish { continuation.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    static func runSerializedCallback(
        key: ObjectIdentifier,
        deadline: Date?,
        start: @escaping (@escaping @Sendable () -> Void) -> Void) async throws
    {
        while let pending = self.pendingCookieStoreMutations[key] {
            try await self.waitForMutation(pending.task, deadline: deadline)
            if self.pendingCookieStoreMutations[key]?.token == pending.token {
                self.pendingCookieStoreMutations[key] = nil
            }
        }

        let token = UUID()
        let task = Task { @MainActor in
            await withCheckedContinuation { continuation in
                start { continuation.resume() }
            }
        }
        self.pendingCookieStoreMutations[key] = PendingCookieStoreMutation(token: token, task: task)
        Task { @MainActor in
            await task.value
            if self.pendingCookieStoreMutations[key]?.token == token {
                self.pendingCookieStoreMutations[key] = nil
            }
        }
        try await self.waitForMutation(task, deadline: deadline)
    }

    private static func waitForMutation(_ task: Task<Void, Never>, deadline: Date?) async throws {
        try await self.runBoundedCallback(deadline: deadline) { completion in
            Task { @MainActor in
                await task.value
                completion()
            }
        }
    }
}
#endif
