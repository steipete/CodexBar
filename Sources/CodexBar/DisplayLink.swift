import AppKit
import Observation
import QuartzCore

/// Minimal CADisplayLink driver using NSScreen.displayLink on macOS 15,
/// and falling back to plain CADisplayLink on macOS 14.
/// Publishes ticks on the main thread at the requested frame rate.
@MainActor
@Observable
final class DisplayLinkDriver {
    // Published counter used to drive SwiftUI updates.
    var tick: Int = 0
    private var link: CADisplayLink?
    private var timer: Timer?

    func start(fps: Double = 12) {
        guard self.link == nil else { return }
        let rate = Float(fps)
        if #available(macOS 15, *), let screen = NSScreen.main {
            let displayLink = screen.displayLink(target: self, selector: #selector(self.step))
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate,
                maximum: rate,
                preferred: rate)
            displayLink.add(to: .main, forMode: .common)
            self.link = displayLink
        } else {
            let interval = max(1.0 / Double(rate), 1.0 / 60.0)
            let timer = Timer(
                timeInterval: interval,
                target: self,
                selector: #selector(self.step),
                userInfo: nil,
                repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        self.link?.invalidate()
        self.link = nil
        self.timer?.invalidate()
        self.timer = nil
    }

    @objc private func step(_: AnyObject) {
        // Safe on main runloop; drives SwiftUI updates.
        self.tick &+= 1
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
