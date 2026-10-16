import Foundation
import Testing
@testable import CodexBarCore

struct UserProviderPluginHTTPClientTests {
    @Test
    func `user plugin http client is released after its request ends`() async {
        let released = await Self.clientIsReleasedAfterRequest()
        #expect(released)
    }

    private static func clientIsReleasedAfterRequest() async -> Bool {
        weak var weakClient: UserProviderPluginHTTPClient?
        do {
            let client = UserProviderPluginHTTPClient(maximumResponseBytes: 1024)
            weakClient = client
            var request = URLRequest(url: URL(string: "http://127.0.0.1:1/")!)
            request.timeoutInterval = 2
            _ = try? await client.data(for: request)
        }
        for _ in 0..<25 where weakClient != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return weakClient == nil
    }
}
