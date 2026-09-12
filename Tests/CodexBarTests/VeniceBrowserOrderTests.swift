import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct VeniceBrowserOrderTests {
    @Test
    func `venice web import tries chrome then brave`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.venice])
        #expect(metadata.browserCookieOrder == [.chrome, .brave])
    }
}
#endif
