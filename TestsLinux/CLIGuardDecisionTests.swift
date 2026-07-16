import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLIGuardDecisionTests {
    @Test
    func `ample headroom is ok and exits zero`() {
        let result = CodexBarCLI.evaluateGuard(remainingPercent: 74, needPercent: 10, failOpen: false)
        #expect(result.decision == .ok)
        #expect(result.exitCode == 0)
    }

    @Test
    func `insufficient headroom is blocked and exits one`() {
        let result = CodexBarCLI.evaluateGuard(remainingPercent: 5, needPercent: 10, failOpen: false)
        #expect(result.decision == .blocked)
        #expect(result.exitCode == 1)
    }

    @Test
    func `unknown remaining exits two by default`() {
        let result = CodexBarCLI.evaluateGuard(remainingPercent: nil, needPercent: 10, failOpen: false)
        #expect(result.decision == .unknown)
        #expect(result.exitCode == 2)
    }

    @Test
    func `unknown remaining with fail-open exits zero`() {
        let result = CodexBarCLI.evaluateGuard(remainingPercent: nil, needPercent: 10, failOpen: true)
        #expect(result.decision == .unknown)
        #expect(result.exitCode == 0)
    }

    @Test
    func `remaining exactly equal to need is ok`() {
        let result = CodexBarCLI.evaluateGuard(remainingPercent: 10, needPercent: 10, failOpen: false)
        #expect(result.decision == .ok)
        #expect(result.exitCode == 0)
    }
}
