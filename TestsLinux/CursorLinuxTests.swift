#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CursorLinuxTests {
    @Test
    func `Cursor automatic source without manual cookies requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    @Test
    func `Cursor descriptor accepts explicit web source`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.web))
    }

    @Test
    func `Cursor usage split labels match Cursor and Third Party`() {
        let metadata = CursorProviderDescriptor.descriptor.metadata
        #expect(metadata.sessionLabel == "Total")
        #expect(metadata.weeklyLabel == "Cursor")
        #expect(metadata.opusLabel == "Third Party")
    }

    @Test
    func `Cursor manual cookie does not require macOS web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "WorkosCursorSessionToken=test"))))
    }

    @Test
    func `empty Cursor manual cookie still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "  "))))
    }

    @Test
    func `disabled Cursor web source still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .off, manualCookieHeader: nil))))
    }
}
#endif
