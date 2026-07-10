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

    @Test
    func `kimi K2 metadata identifies the unofficial provider and its credits dashboard`() throws {
        let meta = try #require(ProviderDefaults.metadata[.kimik2])

        #expect(meta.displayName == "Kimi K2 (unofficial)")
        #expect(meta.toggleTitle == "Show unofficial Kimi K2 usage")
        // The dashboard URL must be a human-facing browser page, not the bearer-token
        // credits API endpoint (which returns HTTP 401 to an unauthenticated browser).
        #expect(meta.dashboardURL == "https://kimrel.com/my-credits")
    }
}
