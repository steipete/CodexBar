import CodexBarCore
import Testing

@Suite
struct OpenAIDashboardBrowserCookieImporterTests {
    @Test
    func mismatchErrorMentionsSourceLabel() {
        let err = OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
            found: [
                .init(sourceLabel: "Safari", email: "a@example.com"),
                .init(sourceLabel: "Chrome", email: "b@example.com"),
            ])
        let msg = err.localizedDescription
        #expect(msg.contains("Safari=a@example.com"))
        #expect(msg.contains("Chrome=b@example.com"))
    }

    @Test
    func manualHeaderSessionCookieDetectionRecognizesExpectedNames() {
        let pairsA = CookieHeaderNormalizer.pairs(from: "__Secure-next-auth.session-token=abc; oai-sc=def")
        #expect(OpenAIDashboardBrowserCookieImporter.manualHeaderContainsSessionCookie(pairs: pairsA))

        let pairsB = CookieHeaderNormalizer.pairs(from: "__Secure-next-auth.session-token.0=abc; __Secure-next-auth.session-token.1=def")
        #expect(OpenAIDashboardBrowserCookieImporter.manualHeaderContainsSessionCookie(pairs: pairsB))
    }

    @Test
    func manualHeaderSessionCookieDetectionRejectsNonSessionCookies() {
        let pairs = CookieHeaderNormalizer.pairs(from: "oai-sc=abc; _puid=def; cf_clearance=ghi")
        #expect(!OpenAIDashboardBrowserCookieImporter.manualHeaderContainsSessionCookie(pairs: pairs))
    }

    @Test
    func loginRequiredErrorMessageDiffersFromInvalidHeader() {
        let invalid = OpenAIDashboardBrowserCookieImporter.ImportError.manualCookieHeaderInvalid.localizedDescription
        let login = OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin.localizedDescription
        #expect(invalid != login)
    }
}
