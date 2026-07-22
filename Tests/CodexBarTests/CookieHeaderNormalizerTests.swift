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

    @Test
    func `embedded cookie marker remains value data`() {
        let header = "__Secure-session=my-cookie:session=abc"

        #expect(CookieHeaderNormalizer.normalize(header) == header)
        #expect(CookieHeaderNormalizer.pairs(from: header).first?.name == "__Secure-session")
        #expect(CookieHeaderNormalizer.pairs(from: header).first?.value == "my-cookie:session=abc")
    }

    @Test
    func `cookie header after another header line is normalized`() {
        let raw = """
        Host: ollama.com
          Cookie: __Secure-session=abc
        Accept: text/html
        """

        #expect(CookieHeaderNormalizer.normalize(raw) == "__Secure-session=abc")
    }
}
