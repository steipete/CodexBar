import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct VeniceBrowserOrderTests {
    @Test
    func `venice web import defaults to chrome`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.venice])
        #expect(metadata.browserCookieOrder == [.chrome])
    }
}
#endif
