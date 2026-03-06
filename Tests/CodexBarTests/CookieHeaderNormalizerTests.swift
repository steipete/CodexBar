import CodexBarCore
import Testing

@Suite
struct CookieHeaderNormalizerTests {
    @Test
    func normalizeDoesNotTreatTokenSubstringsAsCommandFlags() {
        let raw = "__Secure-next-auth.session-token=abc-bdef; oai-sc=xyz"
        let normalized = CookieHeaderNormalizer.normalize(raw)

        #expect(normalized == raw)
    }

    @Test
    func pairsPreserveSessionTokenWhenValueContainsDashB() {
        let raw = "__Secure-next-auth.session-token=abc-bdef; oai-sc=xyz"
        let pairs = CookieHeaderNormalizer.pairs(from: raw)

        #expect(pairs.contains { $0.name == "__Secure-next-auth.session-token" })
        #expect(pairs.contains { $0.name == "oai-sc" })
    }
}
