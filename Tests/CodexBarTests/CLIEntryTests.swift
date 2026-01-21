import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLIEntryTests {
    @Test
    func effectiveArgvDefaultsToUsage() {
        #expect(CodexBarCLI.effectiveArgv([]) == ["usage"])
        #expect(CodexBarCLI.effectiveArgv(["--json"]) == ["usage", "--json"])
        #expect(CodexBarCLI.effectiveArgv(["usage", "--json"]) == ["usage", "--json"])
    }

    @Test
    func decodesFormatFromOptionsAndFlags() {
        let jsonOption = ParsedValues(positional: [], options: ["format": ["json"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: jsonOption) == .json)

        let jsonFlag = ParsedValues(positional: [], options: [:], flags: ["json"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: jsonFlag) == .json)

        let textDefault = ParsedValues(positional: [], options: [:], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: textDefault) == .text)
    }

    @Test
    func providerSelectionPrefersOverride() {
        let selection = CodexBarCLI.providerSelection(rawOverride: "codex", enabled: [.claude, .gemini])
        #expect(selection.asList == [.codex])
    }

    @Test
    func normalizeVersionExtractsNumeric() {
        #expect(CodexBarCLI.normalizeVersion(raw: "codex 1.2.3 (build 4)") == "1.2.3")
        #expect(CodexBarCLI.normalizeVersion(raw: "  v2.0  ") == "2.0")
    }

    @Test
    func makeHeaderIncludesVersionWhenAvailable() {
        let header = CodexBarCLI.makeHeader(provider: .codex, version: "1.2.3", source: "cli")
        #expect(header.contains("Codex"))
        #expect(header.contains("1.2.3"))
        #expect(header.contains("cli"))
    }

    @Test
    func renderOpenAIWebDashboardTextIncludesSummary() {
        let event = CreditEvent(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            service: "codex",
            creditsUsed: 10)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 45,
            creditEvents: [event],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let text = CodexBarCLI.renderOpenAIWebDashboardText(snapshot)

        #expect(text.contains("Web session: user@example.com"))
        #expect(text.contains("Code review: 45% remaining"))
        #expect(text.contains("Web history: 1 events"))
    }

    @Test
    func mapsErrorsToExitCodes() {
        #expect(CodexBarCLI.mapError(CodexStatusProbeError.codexNotInstalled) == ExitCode(2))
        #expect(CodexBarCLI.mapError(CodexStatusProbeError.timedOut) == ExitCode(4))
        #expect(CodexBarCLI.mapError(UsageError.noRateLimitsFound) == ExitCode(3))
    }

    @Test
    func providerSelectionFallsBackToBothForPrimaryPair() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .claude])
        switch selection {
        case .both:
            break
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func providerSelectionFallsBackToCustomWhenNonPrimary() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .gemini])
        switch selection {
        case let .custom(providers):
            #expect(providers == [.codex, .gemini])
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func providerSelectionDefaultsToCodexWhenEmpty() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        switch selection {
        case let .single(provider):
            #expect(provider == .codex)
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func decodesSourceAndTimeoutOptions() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--web-timeout", "45", "--source", "oauth"])
        #expect(CodexBarCLI._decodeWebTimeoutForTesting(from: parsed) == 45)
        #expect(CodexBarCLI._decodeSourceModeForTesting(from: parsed) == .oauth)

        let parsedWeb = try parser.parse(arguments: ["--web"])
        #expect(CodexBarCLI._decodeSourceModeForTesting(from: parsedWeb) == .web)
    }

    @Test
    func shouldUseColorRespectsFormatAndFlags() {
        #expect(!CodexBarCLI.shouldUseColor(noColor: true, format: .text))
        #expect(!CodexBarCLI.shouldUseColor(noColor: false, format: .json))
    }
}
