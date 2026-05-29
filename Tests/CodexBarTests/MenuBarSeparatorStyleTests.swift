import Foundation
import Testing
@testable import CodexBar

struct MenuBarSeparatorStyleTests {
    @Test
    func separatorCharacters() {
        #expect(MenuBarSeparatorStyle.dot.separator == " · ")
        #expect(MenuBarSeparatorStyle.pipe.separator == " | ")
    }

    @Test
    func idMatchesRawValue() {
        for style in MenuBarSeparatorStyle.allCases {
            #expect(style.id == style.rawValue)
        }
    }

    @Test
    func allCasesCoverDotAndPipe() {
        #expect(MenuBarSeparatorStyle.allCases == [.dot, .pipe])
    }

    @Test
    func rawValueRoundTripFallsBackToDot() {
        #expect(MenuBarSeparatorStyle(rawValue: "dot") == .dot)
        #expect(MenuBarSeparatorStyle(rawValue: "pipe") == .pipe)
        #expect(MenuBarSeparatorStyle(rawValue: "garbage") == nil)
    }
}
