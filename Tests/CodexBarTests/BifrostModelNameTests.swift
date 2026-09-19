import Testing
@testable import CodexBarCore

struct BifrostModelNameTests {
    @Test
    func `strips geo and vendor prefixes and the bedrock revision suffix`() {
        #expect(BifrostModelName.display("us.anthropic.claude-sonnet-5") == "claude-sonnet-5")
        #expect(
            BifrostModelName.display("us.anthropic.claude-haiku-4-5-20251001-v1:0") ==
                "claude-haiku-4-5")
    }

    @Test
    func `strips a vendor prefix without a geo prefix`() {
        #expect(
            BifrostModelName.display("anthropic.claude-3-5-sonnet-20241022-v2:0") ==
                "claude-3-5-sonnet")
    }

    @Test
    func `strips non anthropic vendor prefixes`() {
        #expect(BifrostModelName.display("amazon.nova-pro-v1:0") == "nova-pro")
        #expect(BifrostModelName.display("meta.llama3-70b-instruct-v1:0") == "llama3-70b-instruct")
    }

    @Test
    func `prefers the longest matching geo prefix`() {
        #expect(BifrostModelName.display("us-gov.anthropic.claude-sonnet-5") == "claude-sonnet-5")
    }

    @Test
    func `leaves dotted version numbers untouched`() {
        // These dots are part of the version, not a geo/vendor routing prefix. A positional
        // split on "." would corrupt them; the prefix allowlist must not.
        #expect(BifrostModelName.display("gpt-4.1") == "gpt-4.1")
        #expect(BifrostModelName.display("claude-3.5-sonnet") == "claude-3.5-sonnet")
        #expect(BifrostModelName.display("gemini-1.5-pro") == "gemini-1.5-pro")
        #expect(BifrostModelName.display("gpt-4o") == "gpt-4o")
    }

    @Test
    func `falls back to the original when empty or blank`() {
        #expect(BifrostModelName.display("").isEmpty)
        #expect(BifrostModelName.display("   ") == "   ")
    }
}
