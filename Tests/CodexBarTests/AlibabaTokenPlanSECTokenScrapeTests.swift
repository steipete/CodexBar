import Testing
@testable import CodexBarCore

struct AlibabaTokenPlanSECTokenScrapeTests {
    @Test
    func `extracts the OneConsole SEC_TOKEN embedded in the dashboard shell`() {
        // The aliyun OneConsole shell embeds the token as an upper-case, unquoted key inside
        // `window.ALIYUN_CONSOLE_CONFIG` — the shape the mainland Personal/Solo gateway requires.
        let html = """
        <script>
          window.ALIYUN_CONSOLE_CONFIG = {
            LANG: "zh",
            SEC_TOKEN: "NwsiCAv9SDsHsNab4Jexample",
            ACCOUNT_NAME: "someone"
          };
        </script>
        """
        #expect(AlibabaTokenPlanUsageFetcher.extractSECToken(from: html) == "NwsiCAv9SDsHsNab4Jexample")
    }

    @Test
    func `still extracts the lower-case secToken and sec_token shapes`() {
        #expect(
            AlibabaTokenPlanUsageFetcher.extractSECToken(from: #"{"secToken":"abc123"}"#) == "abc123")
        #expect(
            AlibabaTokenPlanUsageFetcher.extractSECToken(from: #"var x = { sec_token: 'def456' };"#) == "def456")
    }

    @Test
    func `returns nil when no token is present`() {
        #expect(AlibabaTokenPlanUsageFetcher.extractSECToken(from: "<html><body>no token here</body></html>") == nil)
    }
}
