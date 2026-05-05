import Testing
@testable import CodexBar

struct ClaudeResilienceTests {
    @Test
    func `suppresses single flake when prior data exists`() {
        var gate = ConsecutiveFailureGate()
        let firstFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        let secondFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(firstFailure == false)
        #expect(secondFailure == true)
    }

    @Test
    func `surfaces failure without prior data`() {
        var gate = ConsecutiveFailureGate()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: false)
        #expect(shouldSurface)
    }

    @Test
    func `resets after success`() {
        var gate = ConsecutiveFailureGate()
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        gate.recordSuccess()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(shouldSurface == false)
    }
}
