import Foundation
import Testing
@testable import CodexBarCore

struct ZoomMateProviderTests {
    @Test
    func `manual captures keep authorization and cookies behind the declared origin`() throws {
        for host in ["ai.zoom.us", "zoommate.zoom.us"] {
            let capture = try #require(ZoomMateProviderDescriptor.capture(
                "curl 'https://\(host)/ai-computer/api/v1/credits/status' -H 'Authorization: Bearer fixture' " +
                    "-H 'Cookie: session=fixture' -H 'Host: attacker.test' -H 'Origin: https://attacker.test'"))
            #expect(capture.host == host)
            #expect(capture.headers["authorization"] == "Bearer fixture")
            #expect(capture.headers["cookie"] == "session=fixture")
            #expect(capture.headers["host"] == nil)
            #expect(capture.headers["origin"] == nil)
        }
    }

    @Test(arguments: [
        "http://ai.zoom.us/ai-computer/api/v1/credits/status",
        "https://ai.zoom.us:443/ai-computer/api/v1/credits/status",
        "https://user@ai.zoom.us/ai-computer/api/v1/credits/status",
        "https://other.zoom.us/ai-computer/api/v1/credits/status",
        "https://ai.zoom.us/ai-computer/api/v1/credits/status?query=bad",
        "https://ai.zoom.us/ai-computer/api/v1/credits/status#fragment",
        "https://ai.zoom.us/ai-computer/api/v1/login/",
    ])
    func `off boundary manual capture URLs are rejected`(url: String) {
        #expect(ZoomMateProviderDescriptor.capture("curl '\(url)' -H 'Authorization: Bearer fixture'") == nil)
    }

    @Test
    func `manual capture requires authorization`() {
        #expect(ZoomMateProviderDescriptor
            .capture("curl https://ai.zoom.us/ai-computer/api/v1/credits/status -H 'Cookie: session=fixture'") == nil)
        #expect(ZoomMateProviderDescriptor.capture("") == nil)
    }
}
