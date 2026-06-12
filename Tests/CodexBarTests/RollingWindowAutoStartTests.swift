import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct RollingWindowAutoStartTests {
    @Test
    func `setting is disabled by default and persists when enabled`() throws {
        let suite = "RollingWindowAutoStartTests-setting"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == false)

        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == true)
        #expect(settings.providerConfig(for: .codex)?.rollingWindowAutoStartEnabled == true)

        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: false)

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == false)
        #expect(settings.providerConfig(for: .codex)?.rollingWindowAutoStartEnabled == nil)
    }

    @Test
    func `decision starts when previous rolling window expired and provider data has no active replacement`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision?.resetAt == expired)
    }

    @Test
    func `decision skips when provider data already has active rolling window`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(5 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `only known prompt harness providers expose auto start support`() {
        #expect(RollingWindowAutoStartSupport.providers == [.codex, .claude, .opencode])
        #expect(RollingWindowPingStarter.command(provider: .opencodego, environment: [:]) == nil)
        #expect(RollingWindowPingStarter.command(provider: .zai, environment: [:]) == nil)
    }

    @Test
    func `codex command uses ephemeral low reasoning mini model by default`() throws {
        let command = try #require(RollingWindowPingStarter.command(provider: .codex, environment: [:]))

        #expect(command.arguments.contains("exec"))
        #expect(command.arguments.contains("--ephemeral"))
        #expect(command.arguments.contains("--skip-git-repo-check"))
        #expect(command.arguments.contains("gpt-5.4-mini"))
        #expect(command.arguments.contains("model_reasoning_effort=\"low\""))
        #expect(command.arguments.last == "hi")
    }

    private static func snapshot(
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        updatedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: updatedAt)
    }
}
