import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherLayoutTests {
    @Test
    func `overview switcher segment matches provider segment height when quota bars are present`() throws {
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
        let overviewFrame = try #require(frames.first)

        for frame in frames.dropFirst() {
            #expect(frame.height == overviewFrame.height)
            #expect(frame.minY == overviewFrame.minY)
            #expect(frame.maxY == overviewFrame.maxY)
        }

        #expect(view._test_rowHeight() == 36)
    }

    @Test
    func `quota bars do not offset inline switcher content`() throws {
        let view = ProviderSwitcherView(
            providers: [.codex, .devin],
            selected: .provider(.codex),
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                provider == .devin ? 50 : nil
            },
            onSelect: { _ in })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let buttonFrames = view._test_buttonFrames()
        let contentFrames = view._test_buttonContentFrames()
        let trackFrames = view._test_quotaIndicatorTrackFrames()
        #expect(buttonFrames.count == 3)
        #expect(contentFrames.count == 3)
        #expect(trackFrames.count == 1)
        #expect(view._test_rowHeight() == 30)

        let overviewFrame = try #require(buttonFrames.first)
        for (buttonFrame, contentFrame) in zip(buttonFrames, contentFrames) {
            let contentFrame = try #require(contentFrame)
            #expect(buttonFrame.minY == overviewFrame.minY)
            #expect(buttonFrame.maxY == overviewFrame.maxY)
            #expect(abs(contentFrame.midY - buttonFrame.height / 2) < 0.01)
        }

        let devinButtonFrame = try #require(buttonFrames.last)
        let devinTrackFrame = try #require(trackFrames.first)
        #expect(devinButtonFrame.height == 30)
        #expect(devinTrackFrame.minY >= devinButtonFrame.minY)
        #expect(devinTrackFrame.maxY <= devinButtonFrame.maxY)
    }

    @Test
    func `integrated quota indicator selects its provider`() {
        let view = ProviderSwitcherView(
            providers: [.codex, .devin],
            selected: .provider(.codex),
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { $0 == .devin ? 50 : nil },
            onSelect: { _ in })

        #expect(view._test_simulateRuntimeClickOnQuotaIndicator(buttonTag: 2))
    }

    @Test
    func `localized inline switcher titles fit without losing equal sizing`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("tr") {
            for width in stride(from: CGFloat(280), through: CGFloat(330), by: 1) {
                let view = ProviderSwitcherView(
                    providers: [.codex, .devin],
                    selected: .overview,
                    includesOverview: true,
                    width: width,
                    showsIcons: true,
                    iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
                    weeklyRemainingProvider: { _ in nil },
                    onSelect: { _ in })
                view.updateConstraintsForSubtreeIfNeeded()
                view.layoutSubtreeIfNeeded()

                let frames = view._test_buttonFrames()
                let desiredWidths = view._test_buttonDesiredWidths()
                #expect(frames.count == 3)
                #expect(desiredWidths.count == frames.count)
                let firstWidth = try #require(frames.first?.width)

                for (frame, desiredWidth) in zip(frames, desiredWidths) {
                    #expect(frame.width == firstWidth)
                    let minimalInsetAllowedWidth = floor((width - 12 - 2) / 3)
                    let evenMinimalInsetAllowedWidth = minimalInsetAllowedWidth
                        .truncatingRemainder(dividingBy: 2) == 0
                        ? minimalInsetAllowedWidth
                        : minimalInsetAllowedWidth - 1
                    let roundedDesiredWidth = ceil(desiredWidth)
                    let evenDesiredWidth = roundedDesiredWidth.truncatingRemainder(dividingBy: 2) == 0
                        ? roundedDesiredWidth
                        : roundedDesiredWidth + 1
                    if evenMinimalInsetAllowedWidth >= evenDesiredWidth {
                        #expect(frame.width >= desiredWidth)
                    }
                }
            }
        }
    }
}
