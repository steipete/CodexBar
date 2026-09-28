import Foundation
import Testing
@testable import CodexBarCore

struct KimiAPIErrorTests {
    @Test(arguments: [KimiAPIError.expiredCodeCredential, .invalidCodeCredential])
    func `CLI credential errors explain renewal and app API key setup`(_ error: KimiAPIError) {
        #expect(error.localizedDescription.contains("Run kimi"))
        #expect(error.localizedDescription.contains("Settings > Providers > Kimi"))
        #expect(error.localizedDescription.contains("KIMI_CODE_API_KEY"))
        #expect(error.localizedDescription.contains("does not refresh"))
    }

    @Test
    func `error descriptions are helpful`() {
        #expect(KimiAPIError.missingToken.errorDescription?.contains("missing") == true)
        #expect(KimiAPIError.invalidToken.errorDescription?.contains("invalid") == true)
        #expect(KimiAPIError.missingAPIKey.errorDescription?.contains("Settings > Providers > Kimi") == true)
        #expect(KimiAPIError.missingAPIKey.errorDescription?.contains("KIMI_CODE_API_KEY") == true)
        #expect(KimiAPIError.expiredCodeCredential.errorDescription?.contains("does not refresh") == true)
        #expect(KimiAPIError.invalidCodeCredential.errorDescription?.contains("invalid") == true)
        #expect(KimiAPIError.invalidAPIKey.errorDescription?.contains("API key") == true)
        #expect(KimiAPIError.invalidRequest("Bad request").errorDescription?.contains("Bad request") == true)
        #expect(KimiAPIError.networkError("Timeout").errorDescription?.contains("Timeout") == true)
        #expect(KimiAPIError.apiError("HTTP 500").errorDescription?.contains("HTTP 500") == true)
        #expect(KimiAPIError.parseFailed("Invalid JSON").errorDescription?.contains("Invalid JSON") == true)
    }
}
