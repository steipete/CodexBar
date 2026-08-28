import Testing
@testable import CodexBarCore

struct ProviderPlanLineParsingTests {
    @Test
    func `Claude plan matching does not bridge usage lines`() {
        let usageText = """
        Skills, subagents, plugins, and MCP servers
        Noattributiondatayet·accumulatesasyouuseClaude

        dtoday·wtoweek

        Usagecredits
        Usagecreditsareoff·/usage-creditstoturnthemon
        """

        let identity = ClaudeStatusProbe.parseIdentity(usageText: usageText, statusText: nil)

        #expect(identity.loginMethod == nil)
    }

    @Test
    func `Claude plan matching keeps single line phrases`() {
        let identity = ClaudeStatusProbe.parseIdentity(
            usageText: nil,
            statusText: "Sonnet 4.6 · Claude Max · you@example.com")

        #expect(identity.loginMethod == "Max")
    }

    @Test
    func `Kiro legacy plan matching does not bridge lines`() throws {
        let output = """
        |
        KIRO FREE
        ████████████████████████████████████████████████████ 25%
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let snapshot = try KiroStatusProbe().parse(output: output)

        #expect(snapshot.planName == "Kiro")
    }

    @Test
    func `Kiro estimated usage plan matching does not bridge lines`() throws {
        let output = """
        Estimated Usage | resets on 2026-06-01 |
        KIRO FREE
        ████████████████████████████████████████████████████ 25%
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let snapshot = try KiroStatusProbe().parse(output: output)

        #expect(snapshot.planName == "Kiro")
    }

    @Test
    func `Kiro labeled plan matching does not bridge lines`() throws {
        let output = """
        Plan:
        Q Developer Pro
        ████████████████████████████████████████████████████ 25%
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let snapshot = try KiroStatusProbe().parse(output: output)

        #expect(snapshot.planName == "Kiro")
    }
}
