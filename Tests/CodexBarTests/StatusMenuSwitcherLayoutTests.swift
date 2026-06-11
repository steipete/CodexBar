import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherLayoutTests {
    @Test
    func `overview switcher segment matches provider segment height when quota bars are present`() {
        let view = ProviderSwitcherView(
            providers: [.claude, .grok, .cursor],
            selected: .overview,
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let frames = view._test_buttonFrames()
        #expect(frames.count == 4)
        guard let overviewFrame = frames.first else { return }

        for frame in frames.dropFirst() {
            #expect(frame.height == overviewFrame.height)
            #expect(frame.minY == overviewFrame.minY)
            #expect(frame.maxY == overviewFrame.maxY)
        }
    }
}
