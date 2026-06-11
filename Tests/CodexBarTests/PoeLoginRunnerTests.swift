import Foundation
import Testing
@testable import CodexBar

struct PoeLoginRunnerTests {
    @Test
    func `callback parser accepts expected code and state`() {
        let request = """
        GET /callback?code=poe-code&state=expected-state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == "poe-code")
        #expect(callback.returnedState == "expected-state")
        #expect(callback.error == nil)
    }

    @Test
    func `callback parser rejects duplicate tracked query parameters without crashing`() {
        let request = """
        GET /callback?code=poe-code&state=expected-state&state=duplicate-state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == nil)
        #expect(callback.returnedState == nil)
        #expect(callback.error == "invalid_request")
        #expect(callback.errorDescription == "Duplicate callback parameter.")
    }
}
