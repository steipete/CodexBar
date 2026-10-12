import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PreferencesSelectionHistoryTests {
    @Test
    func `selecting panes records back history and clears forward history`() throws {
        let selection = try Self.makeSelection()

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
    func `back and forward walk the visited panes without rewriting history`() throws {
        let selection = try Self.makeSelection()
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
    func `reselecting the current pane does not add history`() throws {
        let selection = try Self.makeSelection()
        selection.pane = .general
        #expect(!selection.canGoBack)
    }

    private static func makeSelection() throws -> PreferencesSelection {
        let suiteName = "PreferencesSelectionHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return PreferencesSelection(userDefaults: defaults)
    }
}
