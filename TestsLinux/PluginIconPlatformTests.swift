import CodexBarCore
import Testing

struct PluginIconPlatformTests {
    @Test
    func `SVG icons are validated only on macOS`() {
        let icon = #"<svg viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#
        #if os(macOS)
        #expect(ProviderPluginIconSVG.isValid(icon))
        #else
        #expect(!ProviderPluginIconSVG.isValid(icon))
        #endif
    }
}
