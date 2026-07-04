import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetCreditOutcomeTests {
    @Test
    func `embedded OAuth inventory prevents a duplicate supplemental GET`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let embedded = Self.resetSnapshot(id: "embedded", now: now)
        let recorder = ResetCreditFetchRecorder()

        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: embedded, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { env in
                await recorder.record(env)
                return Self.resetSnapshot(id: "supplemental", now: now)
            })

        #expect(try Self.usage(from: outcome).codexResetCredits == embedded)
        #expect(await recorder.environments().isEmpty)
    }

    @Test
    func `supplemental inventory uses each scoped account environment once`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let fetcher: UsageStore.CodexResetCreditsFetcher = { env in
            await recorder.record(env)
            let home = env["CODEX_HOME"] ?? "missing"
            return Self.resetSnapshot(id: home, now: now)
        }

        let first = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: fetcher)
        let second = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-b"],
            fetcher: fetcher)

        #expect(try Self.usage(from: first).codexResetCredits?.credits.first?.id ==
            Self.resetSnapshot(id: "/tmp/account-a", now: now).credits.first?.id)
        #expect(try Self.usage(from: second).codexResetCredits?.credits.first?.id ==
            Self.resetSnapshot(id: "/tmp/account-b", now: now).credits.first?.id)
        #expect(await recorder.environments().compactMap { $0["CODEX_HOME"] } == [
            "/tmp/account-a",
            "/tmp/account-b",
        ])
    }

    @Test
    func `failed supplemental GET clears inventory on a successful usage refresh`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { env in
                await recorder.record(env)
                throw ResetCreditFetchTestError.failed
            })

        #expect(try Self.usage(from: outcome).codexResetCredits == nil)
        #expect(await recorder.environments().count == 1)
    }

    @Test
    func `single failed GET restores failure for reset-credit-only O auth usage`() async {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now, primary: nil, strategyID: "codex.oauth"),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { env in
                await recorder.record(env)
                throw ResetCreditFetchTestError.failed
            })

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected no-data failure")
            return
        }
        #expect(error is UsageError)
        #expect(await recorder.environments().count == 1)
    }

    @Test
    func `single GET rescues reset-credit-only O auth usage`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let resetCredits = Self.resetSnapshot(id: "rescued", now: now)
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now, primary: nil, strategyID: "codex.oauth"),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { env in
                await recorder.record(env)
                return resetCredits
            })

        #expect(try Self.usage(from: outcome).codexResetCredits == resetCredits)
        #expect(await recorder.environments().count == 1)
    }

    @Test
    func `supplemental GET cancellation remains a cancelled provider outcome`() async {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { _ in throw CancellationError() })

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected cancellation failure")
            return
        }
        #expect(error is CancellationError)
    }

    @Test
    func `display preference does not strip embedded inventory or issue a duplicate GET`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: Self.resetSnapshot(id: "embedded", now: now), now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            fetcher: { env in
                await recorder.record(env)
                return Self.resetSnapshot(id: "supplemental", now: now)
            })

        #expect(try Self.usage(from: outcome).codexResetCredits == Self.resetSnapshot(id: "embedded", now: now))
        #expect(await recorder.environments().isEmpty)
    }

    private static func outcome(
        resetCredits: CodexRateLimitResetCreditsSnapshot?,
        now: Date,
        primary: RateWindow? = nil,
        strategyID: String = "test") -> ProviderFetchOutcome
    {
        let resolvedPrimary = strategyID == "codex.oauth" ? primary : primary ?? RateWindow(
            usedPercent: 25,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        return ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: resolvedPrimary,
                    secondary: nil,
                    codexResetCredits: resetCredits,
                    updatedAt: now),
                credits: nil,
                dashboard: nil,
                sourceLabel: "test",
                strategyID: strategyID,
                strategyKind: .cli)),
            attempts: [])
    }

    private static func resetSnapshot(id: String, now: Date) -> CodexRateLimitResetCreditsSnapshot {
        CodexRateLimitResetCreditsSnapshot(
            credits: [CodexRateLimitResetCredit(
                id: id,
                resetType: "codex_rate_limits",
                status: .available,
                grantedAt: now,
                expiresAt: now.addingTimeInterval(86400),
                redeemStartedAt: nil,
                redeemedAt: nil,
                title: nil,
                description: nil)],
            availableCount: 1,
            updatedAt: now)
    }

    private static func usage(from outcome: ProviderFetchOutcome) throws -> UsageSnapshot {
        switch outcome.result {
        case let .success(result):
            result.usage
        case let .failure(error):
            throw error
        }
    }
}

private actor ResetCreditFetchRecorder {
    private var capturedEnvironments: [[String: String]] = []

    func record(_ env: [String: String]) {
        self.capturedEnvironments.append(env)
    }

    func environments() -> [[String: String]] {
        self.capturedEnvironments
    }
}

private enum ResetCreditFetchTestError: Error {
    case failed
}
