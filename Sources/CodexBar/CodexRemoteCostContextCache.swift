import CodexBarCore
import CryptoKit
import Foundation
import Observation

/// Cheap presentation inputs. Raw file bytes never enter the cache; only resolved paths and revision digests do.
struct CodexRemoteCostContextInput: Equatable, Sendable {
    let source: CodexRemoteLogSource
    let localCodexHome: URL
    let localScope: String
    let historyDays: Int
    let calendar: Calendar
    let pricingCacheRoot: URL?
    let localCostCacheRoot: URL?
    let sshEnvironment: [String: String]
    let now: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.localCodexHome == rhs.localCodexHome && lhs.localScope == rhs.localScope &&
            lhs.historyDays == rhs.historyDays && lhs.calendar == rhs.calendar &&
            lhs.calendar.startOfDay(for: lhs.now) == rhs.calendar.startOfDay(for: rhs.now) &&
            lhs.pricingCacheRoot == rhs.pricingCacheRoot && lhs.localCostCacheRoot == rhs.localCostCacheRoot &&
            lhs.sshEnvironment == rhs.sshEnvironment
    }

    /// Called exclusively by the cache's detached worker, including symlink resolution and default-path lookup.
    func readContext() throws -> CodexRemoteCostContext {
        try Task.checkCancellation()
        let defaultPricingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        let catalog = (self.pricingCacheRoot ?? defaultPricingRoot)
            .appendingPathComponent("model-pricing/models-dev-v1.json")
        let custom = self.pricingCacheRoot?.appendingPathComponent(CostUsageCustomPricing.fileName)
            ?? CostUsageCustomPricing.defaultFileURL()
        let pricingRevision = [catalog, custom].map { url in
            (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).description } ?? "absent"
        }.joined(separator: ":")
        try Task.checkCancellation()
        return CodexRemoteCostContext(
            source: self.source,
            localCodexHome: self.localCodexHome.resolvingSymlinksInPath(),
            localScope: self.localScope,
            historyDays: self.historyDays,
            calendar: self.calendar,
            day: self.calendar.startOfDay(for: self.now),
            pricingRevision: pricingRevision,
            sshRevision: CodexRemoteLogMirror.configurationFingerprint(environment: self.sshEnvironment),
            pricingCacheRoot: self.pricingCacheRoot,
            localCostCacheRoot: self.localCostCacheRoot,
            now: self.now)
    }
}

/// Renders only read memory. Local filesystem verification is coalesced and never initiates an SSH request.
@MainActor
@Observable
final class CodexRemoteCostContextCache {
    typealias Reader = @Sendable (CodexRemoteCostContextInput) async throws -> CodexRemoteCostContext

    private(set) var value: CodexRemoteCostContext?
    private(set) var revision: UInt64 = 0
    @ObservationIgnored var onResolve: ((CodexRemoteCostContext) -> Void)?
    @ObservationIgnored private var input: CodexRemoteCostContextInput?
    @ObservationIgnored private var verifiedAt: Date?
    @ObservationIgnored private var flight: Flight?
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var inputRevision: UInt64 = 0
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let lifetime: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date

    private struct Flight {
        let id: UInt64
        let input: CodexRemoteCostContextInput
        let inputRevision: UInt64
        let task: Task<CodexRemoteCostContext, any Error>
    }

    init(
        lifetime: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = Date.init,
        reader: @escaping Reader = { try $0.readContext() })
    {
        self.lifetime = lifetime
        self.now = now
        self.reader = reader
    }

    /// Returns true only when an already selected input changed, so the owner can revoke its old combined result.
    @discardableResult
    func select(_ input: CodexRemoteCostContextInput) -> Bool {
        guard self.input != input else { return false }
        let changed = self.input != nil
        self.input = input
        self.inputRevision &+= 1
        self.value = nil
        self.verifiedAt = nil
        self.flight?.task.cancel()
        return changed
    }

    func invalidate() {
        self.input = nil
        self.inputRevision &+= 1
        self.value = nil
        self.verifiedAt = nil
        self.flight?.task.cancel()
    }

    /// An expired revision is withheld until verification finishes. Repeated render lookups share one read.
    func cached(for input: CodexRemoteCostContextInput) -> CodexRemoteCostContext? {
        _ = self.revision
        self.select(input)
        if let verifiedAt = self.verifiedAt {
            let age = self.now().timeIntervalSince(verifiedAt)
            if age >= 0, age < self.lifetime { return self.value }
        }
        if self.flight == nil { _ = self.start(input) }
        return nil
    }

    /// Requires a read started after this call, not a cached or already-running render verification.
    /// Cancelled waiters still drain their worker before returning; late workers cannot install another input's value.
    func fresh(for input: CodexRemoteCostContextInput) async throws -> CodexRemoteCostContext {
        self.select(input)
        if let previous = self.flight {
            let result = await previous.task.result
            self.complete(previous, result: result)
            try Task.checkCancellation()
        }
        guard self.input == input else { throw CancellationError() }
        let current = self.flight ?? self.start(input)
        let result = await current.task.result
        self.complete(current, result: result)
        try Task.checkCancellation()
        guard self.input == input else { throw CancellationError() }
        return try result.get()
    }

    private func start(_ input: CodexRemoteCostContextInput) -> Flight {
        self.sequence &+= 1
        let reader = self.reader
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let context = try await reader(input)
            try Task.checkCancellation()
            return context
        }
        let flight = Flight(id: self.sequence, input: input, inputRevision: self.inputRevision, task: task)
        self.flight = flight
        Task { [weak self] in
            let result = await task.result
            self?.complete(flight, result: result)
        }
        return flight
    }

    private func complete(_ flight: Flight, result: Result<CodexRemoteCostContext, any Error>) {
        guard self.flight?.id == flight.id else { return }
        self.flight = nil
        guard self.input == flight.input, self.inputRevision == flight.inputRevision else {
            if let input = self.input { _ = self.start(input) }
            return
        }
        self.verifiedAt = self.now()
        if case let .success(context) = result {
            self.value = context
            self.onResolve?(context)
        } else {
            self.value = nil
        }
        // A fresh digest can equal the previous value. Still notify a view that withheld an expired result.
        self.revision &+= 1
    }
}
