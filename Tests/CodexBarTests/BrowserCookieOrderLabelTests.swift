import CodexBarCore
import SweetCookieKit
import Testing

@Suite
struct BrowserCookieOrderStatusStringTests {
    #if os(macOS)
    @Test
    func cursorNoSessionIncludesBrowserLoginHint() {
        let order = ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder
        let message = CursorStatusProbeError.noSessionCookie.errorDescription ?? ""
        #expect(message.contains(order.loginHint))
    }

    @Test
    func factoryNoSessionIncludesBrowserLoginHint() {
        let order = ProviderDefaults.metadata[.factory]?.browserCookieOrder ?? Browser.defaultImportOrder
        let message = FactoryStatusProbeError.noSessionCookie.errorDescription ?? ""
        #expect(message.contains(order.loginHint))
    }
    #endif
}
