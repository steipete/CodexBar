import CodexBarCore
import Testing

struct SettingsValueTests {
    @Test(arguments: [
        (nil, nil),
        ("", nil),
        (" \n\t ", nil),
        ("\"", nil),
        ("'", nil),
        ("\"\"", nil),
        ("''", nil),
        ("  \" \t \"  ", nil),
        ("  fixture-token  ", "fixture-token"),
        (" \" fixture-token \" ", "fixture-token"),
        (" ' fixture-token ' ", "fixture-token"),
        ("\"nested 'quotes'\"", "nested 'quotes'"),
        ("\"\"fixture\"\"", "\"fixture\""),
        ("\"mismatched'", "\"mismatched'"),
        ("line one\nline two", "line one\nline two"),
        (" '\u{1F99E}' ", "\u{1F99E}"),
    ] as [(String?, String?)])
    func `settings trim whitespace and unwrap one matching quote layer`(raw: String?, expected: String?) {
        #expect(SettingsValue.cleaned(raw) == expected)
        #expect(ProviderConfig(id: .codex, apiKey: raw).sanitizedAPIKey == expected)
        #expect(ClaudeAdminAPISettingsReader.cleaned(raw) == expected)
        #expect(ClinePassSettingsReader.apiKey(environment: raw.map { ["CLINE_API_KEY": $0] } ?? [:]) == expected)
    }

    @Test
    func `empty first credentials retain provider fallback order`() {
        let environment = ["CLINE_API_KEY": " \" \" ", "CLINEPASS_API_KEY": " 'fallback-token' "]
        #expect(ClinePassSettingsReader.apiKey(environment: environment) == "fallback-token")
        #expect(ClinePassSettingsReader.apiKey(environment: [
            "CLINE_API_KEY": "'preferred-token'",
            "CLINEPASS_API_KEY": "fallback-token",
        ]) == "preferred-token")
    }
}
