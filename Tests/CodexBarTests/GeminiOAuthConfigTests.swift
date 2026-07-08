import CodexBarCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized)
struct GeminiOAuthConfigTests {
    @Test
    func `environment client requires both id and secret`() {
        let previousClientID = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"]
        let previousClientSecret = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"]
        setenv("GEMINI_OAUTH_CLIENT_ID", "env-id", 1)
        unsetenv("GEMINI_OAUTH_CLIENT_SECRET")
        defer {
            if let previousClientID {
                setenv("GEMINI_OAUTH_CLIENT_ID", previousClientID, 1)
            } else {
                unsetenv("GEMINI_OAUTH_CLIENT_ID")
            }
            if let previousClientSecret {
                setenv("GEMINI_OAUTH_CLIENT_SECRET", previousClientSecret, 1)
            }
        }

        #expect(GeminiOAuthConfig.environmentClient() == nil)
    }

    @Test
    func `environment client returns configured credentials`() {
        let previousClientID = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"]
        let previousClientSecret = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"]
        setenv("GEMINI_OAUTH_CLIENT_ID", "env-id", 1)
        setenv("GEMINI_OAUTH_CLIENT_SECRET", "env-secret", 1)
        defer {
            if let previousClientID {
                setenv("GEMINI_OAUTH_CLIENT_ID", previousClientID, 1)
            } else {
                unsetenv("GEMINI_OAUTH_CLIENT_ID")
            }
            if let previousClientSecret {
                setenv("GEMINI_OAUTH_CLIENT_SECRET", previousClientSecret, 1)
            } else {
                unsetenv("GEMINI_OAUTH_CLIENT_SECRET")
            }
        }

        let resolved = GeminiOAuthConfig.environmentClient()
        #expect(resolved?.clientID == "env-id")
        #expect(resolved?.clientSecret == "env-secret")
    }
}
