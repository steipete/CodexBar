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
            includeOptionalUsage: true,
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
            includeOptionalUsage: true,
            fetcher: fetcher)
        let second = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-b"],
            includeOptionalUsage: true,
            fetcher: fetcher)

        #expect(try Self.usage(from: first).codexResetCredits?.credits.first?.id == "/tmp/account-a")
        #expect(try Self.usage(from: second).codexResetCredits?.credits.first?.id == "/tmp/account-b")
        #expect(await recorder.environments().compactMap { $0["CODEX_HOME"] } == [
            "/tmp/account-a",
            "/tmp/account-b",
        ])
    }

    @Test
    func `failed supplemental GET clears inventory on a successful usage refresh`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            includeOptionalUsage: true,
            fetcher: { _ in throw ResetCreditFetchTestError.failed })

        #expect(try Self.usage(from: outcome).codexResetCredits == nil)
    }

    @Test
    func `supplemental GET cancellation remains a cancelled provider outcome`() async {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: nil, now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            includeOptionalUsage: true,
            fetcher: { _ in throw CancellationError() })

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected cancellation failure")
            return
        }
        #expect(error is CancellationError)
    }

    @Test
    func `optional usage gate strips inventory without issuing a GET`() async throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let recorder = ResetCreditFetchRecorder()
        let outcome = await UsageStore.attachingCodexResetCreditsIfNeeded(
            to: Self.outcome(resetCredits: Self.resetSnapshot(id: "embedded", now: now), now: now),
            env: ["CODEX_HOME": "/tmp/account-a"],
            includeOptionalUsage: false,
            fetcher: { env in
                await recorder.record(env)
                return Self.resetSnapshot(id: "supplemental", now: now)
            })

        #expect(try Self.usage(from: outcome).codexResetCredits == nil)
        #expect(await recorder.environments().isEmpty)
    }

    private static func outcome(
        resetCredits: CodexRateLimitResetCreditsSnapshot?,
        now: Date) -> ProviderFetchOutcome
    {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    codexResetCredits: resetCredits,
                    updatedAt: now),
                credits: nil,
                dashboard: nil,
                sourceLabel: "test",
                strategyID: "test",
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
