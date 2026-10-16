import AppKit
import Testing
import Vortex
@testable import CodexBar

@MainActor
struct ScreenConfettiLifetimeTests {
    @Test
    func `upward confetti clears the screen before particle and overlay expiry`() throws {
        let view = ScreenConfettiOverlayView(origin: CGPoint(x: 500, y: 1000), colors: [])
        for (phase, angle) in [270.0, 234, 198, 162, 126, 90].enumerated() {
            let tracer = view.makeFireworkConfettiSystem(
                in: CGSize(width: 1000, height: 1000),
                launchAngle: angle,
                phaseIndex: phase,
                lateralOffset: 0)
            let confetti = try #require(tracer.secondarySystems.first)
            // Use the highest possible launch and fastest upward fragment. Vortex integrates
            // position, damping/lifespan, then acceleration, in screen-height units.
            var y = tracer.position.y
            var velocity = -cos((angle + (angle < 180 ? -6 : 6)) * .pi / 180)
            velocity *= tracer.speed + (velocity < 0 ? 1 : -1) * tracer.speedVariation / 2
            self.advance(y: &y, velocity: &velocity, system: tracer, duration: tracer.lifespan)
            velocity = -(confetti.speed + confetti.speedVariation / 2)
            var fallTime = 0.0
            while y < 1.02 || velocity < 0, fallTime < confetti.lifespan {
                self.advance(y: &y, velocity: &velocity, system: confetti, duration: 1.0 / 60)
                fallTime += 1.0 / 60
            }
            #expect(y >= 1.02, "Phase \(phase) expires before clearing the bottom edge")
            let lastExit = Double(phase) * 0.06 + tracer.emissionDuration + tracer.lifespan
                + confetti.emissionDuration + fallTime
            #expect(lastExit < ScreenConfettiOverlayController.overlayLifetime)
        }
    }

    private func advance(y: inout Double, velocity: inout Double, system: VortexSystem, duration: Double) {
        let steps = Int(ceil(duration * 60))
        let delta = duration / Double(steps)
        for _ in 0..<steps {
            y += velocity * delta
            velocity -= velocity * system.dampingFactor * delta / system.lifespan
            velocity += system.acceleration.y * delta
        }
    }
}
