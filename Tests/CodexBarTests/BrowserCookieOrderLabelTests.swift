import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieOrderStatusStringTests {
    #if os(macOS)
    @Test
    func `codex cookie import order keeps firefox ahead of extra chromium browsers`() {
        let order = ProviderDefaults.metadata[.codex]?.browserCookieOrder ?? Browser.defaultImportOrder
        #expect(Array(order.prefix(3)) == [.safari, .chrome, .firefox])
    }

    @Test
    func `automatic cookie import includes newly supported chromium browsers`() {
        #expect(Browser.defaultImportOrder.contains(.comet))
        #expect(Browser.defaultImportOrder.contains(.yandex))
    }

    @Test
    func `claude cookie import prefers chrome without dropping fallback browsers`() throws {
        let order = try #require(ProviderDefaults.metadata[.claude]?.browserCookieOrder)

        #expect(order.first == .chrome)
        #expect(order.count == Browser.defaultImportOrder.count)
        #expect(Set(order) == Set(Browser.defaultImportOrder))
    }

    @Test
    func `cursor no session includes browser login hint`() {
        let order = ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder
        let message = CursorStatusProbeError.noSessionCookie.errorDescription ?? ""
        #expect(message.contains(order.loginHint))
    }

    @Test
    func `cursor no session shows full disk access hint before browser list`() throws {
        let order = ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder
        let message = try #require(CursorStatusProbeError.noSessionCookie.errorDescription)
        let fullDiskAccessRange = try #require(message.range(of: CursorStatusProbeError.safariFullDiskAccessHint))
        let browserListRange = try #require(message.range(of: order.loginHint))

        #expect(fullDiskAccessRange.lowerBound < browserListRange.lowerBound)
    }

    @Test
    func `factory no session includes browser login hint`() {
        let order = ProviderDefaults.metadata[.factory]?.browserCookieOrder ?? Browser.defaultImportOrder
        let message = FactoryStatusProbeError.noSessionCookie.errorDescription ?? ""
        #expect(message.contains(order.loginHint))
    }

    @Test
    func `opencode go automatic cookies use full provider browser order`() {
        let order = OpenCodeWebCookieSupport.automaticImportOrder(provider: .opencodego)
        #expect(order == ProviderDefaults.metadata[.opencodego]?.browserCookieOrder)
        #expect(order.contains(.edge))
        #expect(order.contains(.firefox))
    }

    @Test
    func `opencode automatic cookies use the shared browser order`() {
        let order = OpenCodeWebCookieSupport.automaticImportOrder(provider: .opencode)
        #expect(order == ProviderDefaults.metadata[.opencode]?.browserCookieOrder)
        #expect(order == Browser.defaultImportOrder)
    }

    @Test
    func `mistral cookie importer preserves explicit browser overrides`() {
        let order = ProviderDefaults.metadata[.mistral]?.browserCookieOrder ?? Browser.defaultImportOrder
        #expect(order == Browser.defaultImportOrder)
        #expect(MistralCookieImporter.resolvedImportOrder(nil) == order)
        #expect(MistralCookieImporter.resolvedImportOrder([]) == order)
        #expect(MistralCookieImporter.resolvedImportOrder([.firefox]) == [.firefox])
    }

    #endif
}
