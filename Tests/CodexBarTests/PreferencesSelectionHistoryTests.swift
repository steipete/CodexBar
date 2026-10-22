import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PreferencesSelectionHistoryTests {
    @Test
    func `selecting panes records back history and clears forward history`() {
        let selection = Self.makeSelection()

        #expect(!selection.canGoBack)
        #expect(!selection.canGoForward)

        selection.pane = .notifications
        selection.pane = .advanced
        #expect(selection.backStack.map(\.pane) == [.general, .notifications])

        selection.goBack()
        #expect(selection.pane == .notifications)
        #expect(selection.canGoForward)

        selection.pane = .about
        #expect(!selection.canGoForward)
        #expect(selection.backStack.map(\.pane) == [.general, .notifications])
    }

    @Test
    func `back and forward walk the visited panes without rewriting history`() {
        let selection = Self.makeSelection()
        selection.pane = .notifications
        selection.pane = .advanced

        selection.goBack()
        selection.goBack()
        #expect(selection.pane == .general)
        #expect(!selection.canGoBack)

        selection.goForward()
        selection.goForward()
        #expect(selection.pane == .advanced)
        #expect(!selection.canGoForward)
        #expect(selection.backStack.map(\.pane) == [.general, .notifications])
    }

    @Test
    func `reselecting the current pane does not add history`() {
        let selection = Self.makeSelection()
        selection.pane = .general
        #expect(!selection.canGoBack)
        selection.pane = .notifications
        selection.pane = .advanced
        selection.goBack()
        selection.pane = .notifications
        #expect(selection.forwardStack.map(\.pane) == [.advanced])
        #expect(selection.backStack.map(\.pane) == [.general])
    }

    @Test
    func `removed panes cannot be restored with back or forward`() {
        let selection = Self.makeSelection()
        selection.pane = .debug
        selection.pane = .advanced
        selection.goBack()
        #expect(selection.pane == .debug)

        selection.pane = .general
        selection.removeFromHistory { $0 == .debug }

        #expect(!selection.backStack.map(\.pane).contains(.debug))
        #expect(!selection.forwardStack.map(\.pane).contains(.debug))
        selection.goBack()
        #expect(selection.pane != .debug)
    }

    @Test
    func `removing history entries collapses repeats and the current pane`() {
        let selection = Self.makeSelection()
        selection.pane = .debug
        selection.pane = .general
        selection.pane = .debug
        selection.pane = .advanced
        #expect(selection.backStack.map(\.pane) == [.general, .debug, .general, .debug])

        selection.removeFromHistory { $0 == .debug }
        #expect(selection.backStack.map(\.pane) == [.general])

        selection.pane = .general
        selection.pane = .debug
        selection.pane = .advanced
        selection.goBack()
        selection.goBack()
        #expect(selection.pane == .general)
        #expect(selection.forwardStack.map(\.pane) == [.advanced, .debug])

        selection.removeFromHistory { $0 == .debug }
        #expect(selection.forwardStack.map(\.pane) == [.advanced])
    }

    @Test
    func `acknowledgements uses shared back and forward history`() {
        let selection = Self.makeSelection()
        selection.pane = .about
        selection.showAcknowledgements()
        #expect(selection.title == L("link_acknowledgements"))

        selection.goBack()
        #expect(selection.pane == .about)
        #expect(selection.destination.aboutRoute == nil)
        #expect(selection.canGoForward)

        selection.goForward()
        #expect(selection.destination.aboutRoute == .acknowledgements)
        #expect(!selection.canGoForward)

        selection.goBack()
        selection.goBack()
        #expect(selection.pane == .general)
        #expect(!selection.canGoBack)
        selection.goForward()
        #expect(selection.destination.aboutRoute == nil)
        selection.goForward()
        #expect(selection.destination.aboutRoute == .acknowledgements)
    }

    @Test
    func `history restores acknowledgements after visiting another pane`() {
        let selection = Self.makeSelection()
        selection.pane = .about
        selection.showAcknowledgements()
        selection.pane = .advanced

        selection.goBack()
        #expect(selection.pane == .about)
        #expect(selection.destination.aboutRoute == .acknowledgements)
        selection.goForward()
        #expect(selection.pane == .advanced)
        #expect(selection.destination.aboutRoute == nil)
    }

    @Test
    func `explicit About selection returns to root and clears forward history`() {
        let selection = Self.makeSelection()
        selection.pane = .about
        selection.showAcknowledgements()
        selection.pane = .advanced
        selection.goBack()

        selection.requestAboutRoot()
        #expect(selection.pane == .about)
        #expect(selection.destination.aboutRoute == nil)
        #expect(!selection.canGoForward)
        selection.goBack()
        #expect(selection.destination.aboutRoute == .acknowledgements)
    }

    @Test
    func `history pruning preserves distinct About destinations`() {
        let selection = Self.makeSelection()
        selection.pane = .about
        selection.showAcknowledgements()
        selection.pane = .debug
        selection.requestAboutRoot()
        selection.removeFromHistory { $0 == .debug }

        selection.goBack()
        #expect(selection.destination.aboutRoute == .acknowledgements)
        selection.goBack()
        #expect(selection.pane == .about)
        #expect(selection.destination.aboutRoute == nil)
    }

    @Test
    func `acknowledgements persists only the About pane`() {
        let defaults = InMemoryUserDefaults()
        let selection = PreferencesSelection(userDefaults: defaults)
        selection.showAcknowledgements()

        let restored = PreferencesSelection(userDefaults: defaults)
        #expect(restored.pane == .about)
        #expect(restored.destination.aboutRoute == nil)
        #expect(!restored.canGoBack)
    }

    private static func makeSelection() -> PreferencesSelection {
        PreferencesSelection(userDefaults: InMemoryUserDefaults())
    }
}
