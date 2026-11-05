import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexResetCreditAutoRedeemerTests {
    @Test
    func `disabled feature never schedules or consumes a card`() async {
        let clock = RedemptionClock()
        let manager = CodexResetCreditAutoRedeemer(now: clock.now)
        var calls = 0
        manager.update(enabled: false, owner: "fixture-owner", snapshot: Self.snapshot()) { _, _ in
            calls += 1
            return .reset
        } completed: { _ in }
        await Task.yield()
        #expect(manager.plan == nil)
        #expect(calls == 0)
    }

    @Test
    func `schedules earliest eligible credit at exactly five minutes before expiry`() async {
        let clock = RedemptionClock()
        let sleeper = RedemptionDelayRecorder(clock: clock)
        let manager = CodexResetCreditAutoRedeemer(now: clock.now, sleep: { await sleeper.sleep($0) })
        let signal = AsyncStream<Void>.makeStream()
        var consumedID: String?
        let first = Self.credit("first", seconds: 1000)
        let snapshot = Self.snapshot(credits: [Self.credit("later", seconds: 2000), first])
        manager.update(enabled: true, owner: "fixture-owner", snapshot: snapshot) { id, _ in
            consumedID = id
            return .reset
        } completed: { _ in signal.continuation.yield(); signal.continuation.finish() }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await sleeper.delays() == [700])
        #expect(consumedID == first.id)
        #expect(clock.now() == CodexResetCreditRedemptionTests.now.addingTimeInterval(700))
    }

    @Test
    func `an early check schedules a later consume that passes the exact five minute HTTP gate`() async {
        let clock = RedemptionClock()
        let sleeper = RedemptionDelayRecorder(clock: clock)
        let manager = CodexResetCreditAutoRedeemer(now: clock.now, sleep: { await sleeper.sleep($0) })
        let transport = CodexResetCreditRedemptionTests.transport(seconds: 1000)
        let signal = AsyncStream<Void>.makeStream()
        var outcome: CodexResetCreditRedemptionOutcome?
        manager.update(enabled: true, owner: "fixture-owner", snapshot: Self.snapshot()) { id, requestID in
            try await CodexOAuthUsageFetcher.consumeExpiringRateLimitResetCredit(
                stableCreditID: id,
                redeemRequestID: requestID,
                accessToken: "fixture-token",
                accountId: "fixture-account",
                env: ["CODEX_HOME": "/tmp/codexbar-auto-redemption-fixture"],
                now: clock.now,
                isAuthorized: { true },
                session: transport)
        } completed: { result in
            outcome = result
            signal.continuation.yield()
            signal.continuation.finish()
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await sleeper.delays() == [700])
        #expect(outcome == .reset)
        #expect(await transport.requests().map(\.httpMethod) == ["GET", "POST"])
    }

    @Test
    func `repeated refreshes do not duplicate a queued or completed redemption`() async {
        let clock = RedemptionClock()
        let sleeper = RedemptionDelayRecorder(clock: clock)
        let manager = CodexResetCreditAutoRedeemer(now: clock.now, sleep: { await sleeper.sleep($0) })
        let signal = AsyncStream<Void>.makeStream()
        var calls = 0
        let consume: @MainActor (String, UUID) async throws -> CodexResetCreditRedemptionOutcome = { _, _ in
            calls += 1
            return .reset
        }
        let completed: @MainActor (CodexResetCreditRedemptionOutcome?) async -> Void = { _ in
            signal.continuation.yield()
        }
        for _ in 0..<3 {
            manager.update(
                enabled: true,
                owner: "fixture-owner",
                snapshot: Self.snapshot(),
                consume: consume,
                completed: completed)
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        manager.update(
            enabled: true,
            owner: "fixture-owner",
            snapshot: Self.snapshot(),
            consume: consume,
            completed: completed)
        await Task.yield()
        signal.continuation.finish()
        #expect(calls == 1)
        #expect(manager.plan == nil)
    }

    @Test
    func `transport retry keeps its idempotency key and waits a minute`() async {
        let clock = RedemptionClock()
        let sleeper = RedemptionDelayRecorder(clock: clock)
        let manager = CodexResetCreditAutoRedeemer(now: clock.now, sleep: { await sleeper.sleep($0) })
        let signal = AsyncStream<Void>.makeStream()
        var ids: [UUID] = []
        let consume: @MainActor (String, UUID) async throws -> CodexResetCreditRedemptionOutcome = { _, id in
            ids.append(id)
            if ids.count == 1 { throw URLError(.timedOut) }
            return .reset
        }
        let completed: @MainActor (CodexResetCreditRedemptionOutcome?) async -> Void = { _ in
            signal.continuation.yield()
        }
        var iterator = signal.stream.makeAsyncIterator()
        manager.update(
            enabled: true,
            owner: "fixture-owner",
            snapshot: Self.snapshot(),
            consume: consume,
            completed: completed)
        _ = await iterator.next()
        manager.update(
            enabled: true,
            owner: "fixture-owner",
            snapshot: Self.snapshot(),
            consume: consume,
            completed: completed)
        _ = await iterator.next()
        signal.continuation.finish()
        #expect(await sleeper.delays() == [700, 60])
        #expect(ids.count == 2)
        #expect(ids.first == ids.last)
    }

    @Test
    func `disabling cancels a queued redemption`() async {
        let manager = CodexResetCreditAutoRedeemer(now: { CodexResetCreditRedemptionTests.now })
        var calls = 0
        manager.update(enabled: true, owner: "fixture-owner", snapshot: Self.snapshot()) { _, _ in
            calls += 1
            return .reset
        } completed: { _ in }
        manager.update(enabled: false, owner: "fixture-owner", snapshot: Self.snapshot()) { _, _ in
            calls += 1
            return .reset
        } completed: { _ in }
        await Task.yield()
        #expect(manager.plan == nil)
        #expect(calls == 0)
    }

    @Test
    func `account changes discard the former accounts queued request`() async {
        let clock = RedemptionClock()
        let sleeper = RedemptionDelayRecorder(clock: clock)
        let manager = CodexResetCreditAutoRedeemer(now: clock.now, sleep: { await sleeper.sleep($0) })
        let signal = AsyncStream<Void>.makeStream()
        var owners: [String] = []
        for owner in ["former-owner", "current-owner"] {
            manager.update(enabled: true, owner: owner, snapshot: Self.snapshot()) { _, _ in
                owners.append(owner)
                return .reset
            } completed: { _ in signal.continuation.yield(); signal.continuation.finish() }
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(owners == ["current-owner"])
    }

    @Test
    func `unknown owner expired and non-expiring credits never schedule`() {
        let manager = CodexResetCreditAutoRedeemer(now: { CodexResetCreditRedemptionTests.now })
        for (owner, credits) in [
            (nil, [Self.credit("available", seconds: 300)]),
            ("fixture-owner", [Self.credit("expired", seconds: 0)]),
            ("fixture-owner", [Self.credit("no-expiry", seconds: nil)]),
            ("fixture-owner", []),
        ] as [(String?, [CodexRateLimitResetCredit])] {
            manager.update(enabled: true, owner: owner, snapshot: Self.snapshot(credits: credits)) { _, _ in
                Issue.record("An ineligible credit must never be consumed")
                return .reset
            } completed: { _ in }
            #expect(manager.plan == nil)
        }
    }

    static func credit(_ id: String, seconds: Double?) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: CodexResetCreditRedemptionTests.now.addingTimeInterval(-86400),
            expiresAt: seconds.map { CodexResetCreditRedemptionTests.now.addingTimeInterval($0) },
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }

    static func snapshot(credits: [CodexRateLimitResetCredit]? = nil) -> CodexRateLimitResetCreditsSnapshot {
        CodexRateLimitResetCreditsSnapshot(
            credits: credits ?? [self.credit("fixture-provider-id", seconds: 1000)],
            availableCount: credits?.count ?? 1,
            updatedAt: CodexResetCreditRedemptionTests.now)
    }
}

private final class RedemptionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = CodexResetCreditRedemptionTests.now

    func now() -> Date { self.lock.withLock { self.date } }
    func advance(_ seconds: TimeInterval) { self.lock.withLock { self.date.addTimeInterval(seconds) } }
}

private actor RedemptionDelayRecorder {
    let clock: RedemptionClock
    private var recorded: [TimeInterval] = []

    init(clock: RedemptionClock) { self.clock = clock }
    func sleep(_ seconds: TimeInterval) {
        self.recorded.append(seconds)
        self.clock.advance(seconds)
    }

    func delays() -> [TimeInterval] { self.recorded }
}
