import AppKit
import CodexBarCore
import SwiftUI
import Vortex

@MainActor
final class ScreenConfettiOverlayController {
    private static let overlayLifetime: TimeInterval = 5

    private let logger = CodexBarLog.logger(LogCategories.confetti)
    private var windows: [NSWindow] = []
    private var dismissalTask: Task<Void, Never>?

    func play(originInScreen origin: CGPoint?) {
        guard self.windows.isEmpty else {
            self.logger.debug("Ignoring confetti trigger while overlay is already active")
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            self.logger.error("Cannot present confetti overlay because no screens were found")
            return
        }

        let palette = Self.randomPalette()
        self.windows = screens.map { screen in
            let frame = screen.frame
            let localOrigin = Self.localOrigin(in: frame, from: origin)
            let contentView = ScreenConfettiOverlayView(origin: localOrigin, colors: palette)
                .allowsHitTesting(false)
            let hostingView = NSHostingView(rootView: contentView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor

            let window = ClickThroughOverlayPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen)
            window.contentView = hostingView
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.acceptsMouseMovedEvents = false
            window.isMovable = false
            window.isReleasedWhenClosed = false
            window.canHide = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.isExcludedFromWindowsMenu = true
            window.setFrame(frame, display: false)
            return window
        }

        self.logger.info(
            "Presenting confetti overlay",
            metadata: [
                "screenCount": "\(self.windows.count)",
                "originKnown": origin == nil ? "0" : "1",
            ])

        for window in self.windows {
            window.orderFrontRegardless()
        }

        self.dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.overlayLifetime))
            self?.dismiss()
        }
    }

    func dismiss() {
        self.dismissalTask?.cancel()
        self.dismissalTask = nil

        guard !self.windows.isEmpty else { return }
        for window in self.windows {
            window.orderOut(nil)
            window.close()
        }
        self.windows.removeAll(keepingCapacity: true)
    }

    private static func localOrigin(in screenFrame: CGRect, from globalOrigin: CGPoint?) -> CGPoint {
        let fallback = CGPoint(x: screenFrame.maxX - 28, y: screenFrame.maxY - 8)
        let resolved: CGPoint = if let globalOrigin, screenFrame.contains(globalOrigin) {
            globalOrigin
        } else {
            fallback
        }

        let insetFrame = screenFrame.insetBy(dx: 8, dy: 8)
        return CGPoint(
            x: min(max(resolved.x, insetFrame.minX), insetFrame.maxX) - screenFrame.minX,
            y: min(max(resolved.y, insetFrame.minY), insetFrame.maxY) - screenFrame.minY)
    }

    private static func randomPalette() -> [Color] {
        let hue = Double.random(in: 0...1)
        let hueOffsets = [0.0, 0.08, 0.16, 0.5, 0.66, 0.83]
        return hueOffsets.map { offset in
            Color(
                hue: (hue + offset).truncatingRemainder(dividingBy: 1),
                saturation: Double.random(in: 0.55...0.95),
                brightness: Double.random(in: 0.85...1))
        }
    }
}

private final class ClickThroughOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

private struct ScreenConfettiOverlayView: View {
    private static let clockwiseRotationAngles: [Double] = [270, 234, 198, 162, 126, 90]
    private static let counterclockwiseRotationAngles: [Double] = [90, 126, 162, 198, 234, 270]

    let origin: CGPoint
    let colors: [Color]

    @Environment(\.self) private var environment
    @State private var visiblePhaseCount = 0

    var body: some View {
        GeometryReader { proxy in
            let clockwiseAngles = Array(Self.clockwiseRotationAngles.prefix(self.visiblePhaseCount).enumerated())
            let counterclockwiseAngles = Array(
                Self.counterclockwiseRotationAngles.prefix(self.visiblePhaseCount).enumerated())
            ZStack {
                ForEach(clockwiseAngles, id: \.offset) { index, angle in
                    VortexView(self.makeFireworkConfettiSystem(
                        in: proxy.size,
                        launchAngle: angle,
                        phaseIndex: index,
                        lateralOffset: -12))
                    {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.white)
                            .frame(width: 10, height: 20)
                            .tag("confetti-bar")

                        Circle()
                            .fill(.white)
                            .frame(width: 9, height: 9)
                            .tag("confetti-dot")

                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(width: 8, height: 16)
                            .rotationEffect(.degrees(30))
                            .tag("confetti-pill")

                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .blur(radius: 1)
                            .tag("confetti-tracer")
                    }
                }

                ForEach(counterclockwiseAngles, id: \.offset) { index, angle in
                    VortexView(self.makeFireworkConfettiSystem(
                        in: proxy.size,
                        launchAngle: angle,
                        phaseIndex: index,
                        lateralOffset: 12))
                    {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.white)
                            .frame(width: 10, height: 20)
                            .tag("confetti-bar")

                        Circle()
                            .fill(.white)
                            .frame(width: 9, height: 9)
                            .tag("confetti-dot")

                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(width: 8, height: 16)
                            .rotationEffect(.degrees(30))
                            .tag("confetti-pill")

                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .blur(radius: 1)
                            .tag("confetti-tracer")
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .task {
                self.visiblePhaseCount = 1
                for phaseCount in 2...Self.clockwiseRotationAngles.count {
                    try? await Task.sleep(for: .milliseconds(60))
                    self.visiblePhaseCount = phaseCount
                }
            }
        }
    }

    private func makeFireworkConfettiSystem(
        in size: CGSize,
        launchAngle: Double,
        phaseIndex: Int,
        lateralOffset: CGFloat)
        -> VortexSystem
    {
        let canvasOrigin = self.canvasOrigin(in: size, lateralOffset: lateralOffset)
        let normalizedX = size.width > 0 ? canvasOrigin.x / size.width : 1
        let normalizedY = size.height > 0 ? canvasOrigin.y / size.height : 0
        let resolvedColors = self.colors.map { color -> VortexSystem.Color in
            let components = color.resolve(in: self.environment)
            return VortexSystem.Color(
                red: Double(components.red),
                green: Double(components.green),
                blue: Double(components.blue),
                opacity: Double(components.opacity))
        }

        let explosion = VortexSystem(
            tags: ["confetti-bar", "confetti-dot", "confetti-pill"],
            spawnOccasion: .onDeath,
            shape: .point,
            birthRate: 24000,
            emissionLimit: 42,
            emissionDuration: 0.08,
            idleDuration: 10,
            lifespan: 4.2,
            speed: 0.72,
            speedVariation: 0.44,
            angleRange: .degrees(360),
            acceleration: [0, 0.32],
            dampingFactor: 0.18,
            angularSpeed: [0, 0, 3],
            angularSpeedVariation: [2, 2, 14],
            colors: .random(resolvedColors),
            size: 0.74,
            sizeVariation: 0.26,
            sizeMultiplierAtDeath: 0.94,
            stretchFactor: 0.82)

        return VortexSystem(
            tags: ["confetti-tracer"],
            secondarySystems: [explosion],
            position: [normalizedX, normalizedY],
            shape: .point,
            birthRate: 18,
            emissionLimit: 4,
            emissionDuration: 0.22,
            idleDuration: 10,
            lifespan: 0.58 + (Double(phaseIndex) * 0.03),
            speed: 1.36 + (Double(phaseIndex) * 0.04),
            speedVariation: 0.12,
            angle: .degrees(launchAngle),
            angleRange: .degrees(12),
            acceleration: [0, 0.12],
            dampingFactor: 0.06,
            angularSpeed: [0, 0, 6],
            angularSpeedVariation: [1, 1, 8],
            colors: .single(.white),
            size: 0.34,
            sizeVariation: 0.08,
            sizeMultiplierAtDeath: 0.4,
            stretchFactor: 1.3)
    }

    private func canvasOrigin(in size: CGSize, lateralOffset: CGFloat = 0) -> CGPoint {
        CGPoint(
            x: min(max(self.origin.x + lateralOffset, 0), size.width),
            y: min(max(size.height - self.origin.y + 18, 0), size.height))
    }
}
