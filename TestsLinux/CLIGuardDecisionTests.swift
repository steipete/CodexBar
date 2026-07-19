import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIGuardDecisionTests {
    @Test
    func `ample headroom is ok and exits zero`() {
        let result = CodexBarCLI.evaluateGuard(
            outcome: .available(74),
            minimumRemainingPercent: 10,
            failOpen: false)
        #expect(result.decision == .ok)
        #expect(result.exitCode == 0)
    }

    @Test
    func `insufficient headroom is blocked and exits one`() {
        let result = CodexBarCLI.evaluateGuard(
            outcome: .available(5),
            minimumRemainingPercent: 10,
            failOpen: false)
        #expect(result.decision == .blocked)
        #expect(result.exitCode == 1)
    }

    @Test
    func `fetch failure exits unavailable by default`() {
        let result = CodexBarCLI.evaluateGuard(
            outcome: .unavailable(.fetchFailed),
            minimumRemainingPercent: 10,
            failOpen: false)
        #expect(result.decision == .unknown)
        #expect(result.exitCode == 69)
        #expect(result.unavailableReason == .fetchFailed)
    }

    @Test
    func `unknown remaining with fail-open exits zero`() {
        let result = CodexBarCLI.evaluateGuard(
            outcome: .unavailable(.fetchFailed),
            minimumRemainingPercent: 10,
            failOpen: true)
        #expect(result.decision == .unknown)
        #expect(result.exitCode == 0)
    }

    @Test
    func `remaining exactly equal to need is ok`() {
        let result = CodexBarCLI.evaluateGuard(
            outcome: .available(10),
            minimumRemainingPercent: 10,
            failOpen: false)
        #expect(result.decision == .ok)
        #expect(result.exitCode == 0)
    }

    @Test
    func `unknown provider is rejected`() {
        let result = CodexBarCLI.guardProvider(rawOverride: "definitely-not-a-provider")
        guard case let .failure(error) = result else {
            Issue.record("Expected unknown provider to be rejected")
            return
        }
        #expect(error.localizedDescription == "unknown provider 'definitely-not-a-provider'.")
    }

    @Test
    func `missing provider is rejected`() {
        let result = CodexBarCLI.guardProvider(rawOverride: nil)
        guard case let .failure(error) = result else {
            Issue.record("Expected missing provider to be rejected")
            return
        }
        #expect(error.localizedDescription == "guard requires --provider <id>.")
    }

    @Test
    func `timeout rejects values that could overflow duration`() {
        let result = CodexBarCLI.guardTimeout(raw: "1e100")
        guard case .failure = result else {
            Issue.record("Expected enormous timeout to be rejected")
            return
        }
    }

    @Test
    func `fetch timeout is reported as unavailable`() async {
        let result = await CodexBarCLI.runGuardFetch(timeout: 0.01) {
            try? await Task.sleep(for: .seconds(30))
            return .available(100)
        }
        guard case .unavailable(.timeout) = result else {
            Issue.record("Expected guard fetch to time out")
            return
        }
    }

    // MARK: - Window headroom (synthetic-placeholder filtering)

    private func window(usedPercent: Double, synthetic: Bool) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
    }

    @Test
    func `real window reports remaining headroom`() {
        let remaining = CodexBarCLI.guardRemainingHeadroom(for: self.window(usedPercent: 30, synthetic: false))
        #expect(remaining == 70)
    }

    @Test
    func `synthetic placeholder window is treated as unknown`() {
        let remaining = CodexBarCLI.guardRemainingHeadroom(for: self.window(usedPercent: 0, synthetic: true))
        #expect(remaining == nil)
    }

    @Test
    func `absent window is unknown`() {
        #expect(CodexBarCLI.guardRemainingHeadroom(for: nil) == nil)
    }

    @Test
    func `fully used real window has zero headroom`() {
        let remaining = CodexBarCLI.guardRemainingHeadroom(for: self.window(usedPercent: 100, synthetic: false))
        #expect(remaining == 0)
    }
}
