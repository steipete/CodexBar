import Testing
@testable import CodexBar

@Suite struct AppResourceLocatorTests {
    @Test func resolvesClassicIconResource() {
        let url = AppResourceLocator.url(forResource: "Icon-classic", withExtension: "icns")
        #expect(url != nil)
    }

    @Test func resolvesProviderIconResource() {
        let url = AppResourceLocator.url(forResource: "ProviderIcon-codex", withExtension: "svg")
        #expect(url != nil)
    }
}
