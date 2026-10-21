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
        #expect(selection.backStack == [.general, .notifications])

        selection.goBack()
        #expect(selection.pane == .notifications)
        #expect(selection.canGoForward)

        selection.pane = .about
        #expect(!selection.canGoForward)
        #expect(selection.backStack == [.general, .notifications])
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
        #expect(selection.backStack == [.general, .notifications])
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
        #expect(selection.forwardStack == [.advanced])
        #expect(selection.backStack == [.general])
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

        #expect(!selection.backStack.contains(.debug))
        #expect(!selection.forwardStack.contains(.debug))
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
        #expect(selection.backStack == [.general, .debug, .general, .debug])

        selection.removeFromHistory { $0 == .debug }
        #expect(selection.backStack == [.general])

        selection.pane = .general
        selection.pane = .debug
        selection.pane = .advanced
        selection.goBack()
        selection.goBack()
        #expect(selection.pane == .general)
        #expect(selection.forwardStack == [.advanced, .debug])

        selection.removeFromHistory { $0 == .debug }
        #expect(selection.forwardStack == [.advanced])
    }

    private static func makeSelection() -> PreferencesSelection {
        PreferencesSelection(userDefaults: InMemoryUserDefaults())
    }
}
