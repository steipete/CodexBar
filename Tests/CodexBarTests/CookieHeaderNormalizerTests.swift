import CodexBarCore
import Testing

struct CookieHeaderNormalizerTests {
    @Test
    func `compact curl short form without whitespace still parses`() {
        let normalized = CookieHeaderNormalizer.normalize("curl https://example.com -bfoo=bar")

        #expect(normalized == "foo=bar")
        #expect(CookieHeaderNormalizer.pairs(from: "curl https://example.com -bfoo=bar").count == 1)
        #expect(CookieHeaderNormalizer.pairs(from: "curl https://example.com -bfoo=bar").first?.name == "foo")
        #expect(CookieHeaderNormalizer.pairs(from: "curl https://example.com -bfoo=bar").first?.value == "bar")
    }
}
