import Foundation
import SwiftUI
import Testing
@testable import CodexBarWidget

@Suite("Widget live minute text")
struct WidgetDateTextTests {
    @Test
    func `system age format excludes seconds and advances at a minute boundary`() throws {
        guard #available(macOS 15, *) else { return }
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let style = WidgetDateText.ageFormat(anchor).locale(Locale(identifier: "en_US"))
        let now = anchor.addingTimeInterval(5 * 60 + 10)
        #expect(style.format(now) == style.format(now.addingTimeInterval(1)))
        let next = try #require(style.discreteInput(after: now))
        #expect(next > now)
        #expect(next.timeIntervalSince(now) <= 60)
        #expect(style.format(next) != style.format(now))
        #expect(!String(style.format(now).characters).contains("second"))
    }

    @Test
    func `system reset reference advances without seconds and identifies expiration`() throws {
        guard #available(macOS 15, *) else { return }
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let style = WidgetDateText.resetFormat(reset).locale(Locale(identifier: "en_US"))
        let now = reset.addingTimeInterval(-110)
        let next = try #require(style.discreteInput(after: now))
        #expect(next > now)
        #expect(next.timeIntervalSince(now) <= 60)
        #expect(style.format(next) != style.format(now))
        #expect(!String(style.format(now).characters).contains("second"))
        #expect(String(style.format(reset).characters) == "now")
        #expect(String(style.format(reset.addingTimeInterval(120)).characters).contains("ago"))
    }
}
