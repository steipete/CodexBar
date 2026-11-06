import CodexBarCore
import Foundation

@MainActor
final class CodexResetCreditAutoRedeemer {
    static let leadTime: TimeInterval = 5 * 60

    struct Plan: Equatable {
        let owner: String
        let creditID: String
        let expiresAt: Date
    }

    private(set) var plan: Plan?
    private(set) var task: Task<Void, Never>?
    private var requestIDs: [String: UUID] = [:]
    private var lastAttempts: [String: Date] = [:]
    private var redeemed: Set<String> = []
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
    {
        self.now = now
        self.sleep = sleep
    }

    func update(
        enabled: Bool,
        owner: String?,
        snapshot: CodexRateLimitResetCreditsSnapshot?,
        consume: @escaping @MainActor (String, UUID) async throws -> CodexResetCreditRedemptionOutcome,
        completed: @escaping @MainActor (CodexResetCreditRedemptionOutcome?) async -> Void)
    {
        guard enabled, let owner, let snapshot,
              let credit = snapshot.availableCredits(at: self.now()).first(where: {
                  $0.resetType == "codex_rate_limits" && $0.expiresAt != nil &&
                      !self.redeemed.contains(owner + ":" + $0.id)
              }), let expiry = credit.expiresAt
        else {
            self.cancel()
            return
        }
        let next = Plan(owner: owner, creditID: credit.id, expiresAt: expiry)
        if self.plan == next, self.task != nil { return }
        self.cancel()
        self.plan = next
        let key = owner + ":" + credit.id
        let requestID = self.requestIDs[key] ?? UUID()
        self.requestIDs[key] = requestID
        let fireAt = max(
            expiry.addingTimeInterval(-Self.leadTime),
            self.lastAttempts[key]?.addingTimeInterval(60) ?? .distantPast)
        guard fireAt < expiry else {
            self.plan = nil
            return
        }
        let delay = max(0, fireAt.timeIntervalSince(self.now()))
        let sleep = self.sleep
        self.task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await sleep(delay)
                try Task.checkCancellation()
                guard let self, self.plan == next, next.expiresAt > self.now() else { return }
                self.lastAttempts[key] = self.now()
                let result = try await consume(next.creditID, requestID)
                guard !Task.isCancelled, self.plan == next else { return }
                if result == .reset || result == .alreadyRedeemed {
                    self.redeemed.insert(key)
                    self.requestIDs[key] = nil
                } else if result == .nothingToReset {
                    // A confirmed non-redemption is a new logical attempt on the next refresh.
                    self.requestIDs[key] = nil
                }
                self.task = nil
                self.plan = nil
                await completed(result)
            } catch {
                guard !Task.isCancelled, let self, self.plan == next else { return }
                self.task = nil
                self.plan = nil
                await completed(nil)
            }
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
        self.plan = nil
    }

    deinit {
        self.task?.cancel()
    }
}
