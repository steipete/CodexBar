import CodexBarCore
import SwiftUI

@MainActor
struct IconView: View {
    let snapshot: UsageSnapshot?
    let creditsRemaining: Double?
    let isStale: Bool
    let showLoadingAnimation: Bool
    let style: IconStyle
    @State private var phase: CGFloat = 0
    @State private var displayLink = DisplayLinkDriver()
    @State private var pattern: LoadingPattern = .knightRider
    @State private var debugCycle = false
    @State private var cycleIndex = 0
    @State private var cycleCounter = 0
    private let loadingFPS: Double = 12
    // Advance to next pattern every N ticks when debug cycling.
    private let cycleIntervalTicks = 20
    private let patterns = LoadingPattern.allCases

    private var isLoading: Bool {
        self.showLoadingAnimation && self.snapshot == nil
    }

    var body: some View {
        Group {
            if let snapshot {
                Image(nsImage: IconRenderer.makeIcon(
                    primaryRemaining: snapshot.primary?.remainingPercent,
                    weeklyRemaining: snapshot.secondary?.remainingPercent,
                    creditsRemaining: self.creditsRemaining,
                    stale: self.isStale,
                    style: self.style))
                    .renderingMode(.original)
                    .interpolation(.none)
                    .frame(width: 20, height: 18, alignment: .center)
                    .padding(.horizontal, 2)
            } else if self.showLoadingAnimation {
                // Loading: animate bars with the current pattern until data arrives.
                Image(nsImage: self.loadingImage)
                    .renderingMode(.original)
                    .interpolation(.none)
                    .frame(width: 20, height: 18, alignment: .center)
                    .padding(.horizontal, 2)
                    .onChange(of: self.displayLink.tick) { _, _ in
                        self.phase += 0.09 // half-speed animation
                        if self.debugCycle {
                            self.cycleCounter += 1
                            if self.cycleCounter >= self.cycleIntervalTicks {
                                self.cycleCounter = 0
                                self.cycleIndex = (self.cycleIndex + 1) % self.patterns.count
                                self.pattern = self.patterns[self.cycleIndex]
                            }
                        }
                    }
            } else {
                // No animation when usage/account is unavailable; show empty tracks.
                Image(nsImage: IconRenderer.makeIcon(
                    primaryRemaining: nil,
                    weeklyRemaining: nil,
                    creditsRemaining: self.creditsRemaining,
                    stale: self.isStale,
                    style: self.style))
                    .renderingMode(.original)
                    .interpolation(.none)
                    .frame(width: 20, height: 18, alignment: .center)
                    .padding(.horizontal, 2)
            }
        }
        .onChange(of: self.isLoading, initial: true) { _, isLoading in
            if isLoading {
                self.displayLink.start(fps: self.loadingFPS)
                if !self.debugCycle {
                    self.pattern = self.patterns.randomElement() ?? .knightRider
                }
            } else {
                self.displayLink.stop()
                self.debugCycle = false
                self.phase = 0
            }
        }
        .onDisappear { self.displayLink.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .codexbarDebugReplayAllAnimations)) { notification in
            if let raw = notification.userInfo?["pattern"] as? String,
               let selected = LoadingPattern(rawValue: raw)
            {
                self.debugCycle = false
                self.pattern = selected
                self.cycleIndex = self.patterns.firstIndex(of: selected) ?? 0
            } else {
                self.debugCycle = true
                self.cycleIndex = 0
                self.pattern = self.patterns.first ?? .knightRider
            }
            self.cycleCounter = 0
            self.phase = 0
        }
    }

    private var loadingPrimary: Double {
        self.pattern.value(phase: Double(self.phase))
    }

    private var loadingSecondary: Double {
        self.pattern.value(phase: Double(self.phase + self.pattern.secondaryOffset))
    }

    private var loadingImage: NSImage {
        if self.pattern == .unbraid {
            let progress = self.loadingPrimary / 100
            return IconRenderer.makeMorphIcon(progress: progress, style: self.style)
        } else {
            return IconRenderer.makeIcon(
                primaryRemaining: self.loadingPrimary,
                weeklyRemaining: self.loadingSecondary,
                creditsRemaining: nil,
                stale: false,
                style: self.style)
        }
    }
}
