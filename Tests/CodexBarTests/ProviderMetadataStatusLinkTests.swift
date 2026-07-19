import Testing
@testable import CodexBarCore

struct ProviderMetadataStatusLinkTests {
    @Test
    func `workspace status link matches product ID`() {
        for (provider, meta) in ProviderDefaults.metadata {
            guard let productID = meta.statusWorkspaceProductID else { continue }
            let expected = "https://www.google.com/appsstatus/dashboard/products/\(productID)/history"
            #expect(
                meta.statusLinkURL == expected,
                "Expected \(provider.rawValue) statusLinkURL to be \(expected)")
        }
    }
}
