import CodexBarCore
import Testing

@Suite
struct PlatformGatingTests {
    @Test
    func claudeWebFetcher_isNotSupportedOnLinux() async {
        #if os(Linux)
        let error = await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
            _ = try await ClaudeWebAPIFetcher.fetchUsage()
        }
        let isExpectedError = error.map { thrown in
            if case .notSupportedOnThisPlatform = thrown { return true }
            return false
        } ?? false
        #expect(isExpectedError)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeWebFetcher_hasSessionKey_isFalseOnLinux() {
        #if os(Linux)
        #expect(ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: nil) == false)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func claudeWebFetcher_sessionKeyInfo_throwsOnLinux() {
        #if os(Linux)
        let error = #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
            _ = try ClaudeWebAPIFetcher.sessionKeyInfo()
        }
        let isExpectedError = error.map { thrown in
            if case .notSupportedOnThisPlatform = thrown { return true }
            return false
        } ?? false
        #expect(isExpectedError)
        #else
        #expect(Bool(true))
        #endif
    }
}
