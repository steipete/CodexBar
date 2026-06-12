import CodexBarCore
import Commander
import Foundation
import XCTest
@testable import CodexBarCLI

final class CLIEntryTests: XCTestCase {
    func test_effectiveArgvDefaultsToUsage() {
        XCTAssertEqual(CodexBarCLI.effectiveArgv([]), ["usage"])
        XCTAssertEqual(CodexBarCLI.effectiveArgv(["--json"]), ["usage", "--json"])
        XCTAssertEqual(CodexBarCLI.effectiveArgv(["usage", "--json"]), ["usage", "--json"])
    }

    func test_decodesFormatFromOptionsAndFlags() {
        let jsonOption = ParsedValues(positional: [], options: ["format": ["json"]], flags: [])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: jsonOption), .json)

        let jsonFlag = ParsedValues(positional: [], options: [:], flags: ["json"])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: jsonFlag), .json)

        let textDefault = ParsedValues(positional: [], options: [:], flags: [])
        XCTAssertEqual(CodexBarCLI._decodeFormatForTesting(from: textDefault), .text)
    }

    func test_providerSelectionPrefersOverride() {
        let selection = CodexBarCLI.providerSelection(rawOverride: "codex", enabled: [.claude, .gemini])
        XCTAssertEqual(selection.asList, [.codex])
    }

    func test_normalizeVersionExtractsNumeric() {
        XCTAssertEqual(CodexBarCLI.normalizeVersion(raw: "codex 1.2.3 (build 4)"), "1.2.3")
        XCTAssertEqual(CodexBarCLI.normalizeVersion(raw: "  v2.0  "), "2.0")
    }

    func test_makeHeaderIncludesVersionWhenAvailable() {
        let header = CodexBarCLI.makeHeader(provider: .codex, version: "1.2.3", source: "cli")
        XCTAssertTrue(header.contains("Codex"))
        XCTAssertTrue(header.contains("1.2.3"))
        XCTAssertTrue(header.contains("cli"))
    }

    func test_cliVersionFallsBackToContainingAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        XCTAssertEqual(CodexBarCLI.containingAppVersion(for: helperURL), "9.8.7")
    }

    func test_cliVersionFollowsSymlinkedHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.4.6"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoURL)

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)

        let symlinkURL = binURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        XCTAssertEqual(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: symlinkURL.path), "2.4.6")
    }

    func test_cliVersionFallsBackToAdjacentVersionFile() throws {
        try self.expectAdjacentVersionFile(raw: "v3.2.1\n", expected: "3.2.1")
        try self.expectAdjacentVersionFile(raw: "3.2.2\n", expected: "3.2.2")
        try self.expectAdjacentVersionFile(raw: "version-3.2.3\n", expected: "version-3.2.3")
    }

    func test_cliVersionPrefersAdjacentVersionOverStandaloneBundleName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try "4.5.6\n".write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        XCTAssertEqual(
            CodexBarCLI.currentVersion(bundleVersion: "CodexBar", executablePath: helperURL.path),
            "4.5.6")
    }

    private func expectAdjacentVersionFile(raw: String, expected: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cli-version-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let helperURL = binURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        try raw.write(
            to: binURL.appendingPathComponent("VERSION"),
            atomically: false,
            encoding: .utf8)

        XCTAssertEqual(CodexBarCLI.currentVersion(bundleVersion: nil, executablePath: helperURL.path), expected)
    }

    func test_renderOpenAIWebDashboardTextIncludesSummary() {
        let event = CreditEvent(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            service: "codex",
            creditsUsed: 10)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 45,
            codeReviewLimit: RateWindow(
                usedPercent: 55,
                windowMinutes: nil,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            creditEvents: [event],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let text = CodexBarCLI.renderOpenAIWebDashboardText(snapshot)

        XCTAssertTrue(text.contains("Web session: user@example.com"))
        XCTAssertTrue(text.contains("Code review: 45% remaining (Resets in "))
        XCTAssertTrue(text.contains("Web history: 1 events"))
    }

    func test_mapsErrorsToExitCodes() {
        XCTAssertEqual(CodexBarCLI.mapError(CodexStatusProbeError.codexNotInstalled), ExitCode(2))
        XCTAssertEqual(CodexBarCLI.mapError(CodexStatusProbeError.timedOut), ExitCode(4))
        XCTAssertEqual(CodexBarCLI.mapError(UsageError.noRateLimitsFound), ExitCode(3))
    }

    func test_antigravityPlanDebugKeepsOneShotHelperAliveUntilDebugFetch() {
        XCTAssertTrue(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: false))
        XCTAssertFalse(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .codex,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: false))
        XCTAssertFalse(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: true,
            persistsCLISessions: false))
        XCTAssertFalse(CodexBarCLI.holdsAntigravityCLISessionForPlanDebug(
            provider: .antigravity,
            planDebugEnabled: true,
            jsonOnly: false,
            persistsCLISessions: true))
    }

    func test_missingCodexBinaryErrorPayloadUsesInstallGuidance() {
        let payload = CodexBarCLI.makeErrorPayload(CodexStatusProbeError.codexNotInstalled, kind: .provider)

        XCTAssertEqual(payload.code, ExitCode.binaryNotFound.rawValue)
        XCTAssertTrue(payload.message.contains("Codex CLI missing"))
        XCTAssertFalse(payload.message.contains("Codex not running"))
    }

    func test_providerSelectionFallsBackToBothForPrimaryPair() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .claude])
        switch selection {
        case .both:
            break
        default:
            XCTFail("Expected both selection")
        }
    }

    func test_providerSelectionFallsBackToCustomWhenNonPrimary() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .gemini])
        switch selection {
        case let .custom(providers):
            XCTAssertEqual(providers, [.codex, .gemini])
        default:
            XCTFail("Expected custom selection")
        }
    }

    func test_providerSelectionHonorsEmptyEnabledSet() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        switch selection {
        case let .custom(providers):
            XCTAssertEqual(providers, [])
        default:
            XCTFail("Expected empty custom selection")
        }
    }

    func test_decodesSourceAndTimeoutOptions() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--web-timeout", "45", "--source", "oauth"])
        XCTAssertEqual(CodexBarCLI._decodeWebTimeoutForTesting(from: parsed), 45)
        XCTAssertEqual(CodexBarCLI._decodeSourceModeForTesting(from: parsed), .oauth)

        let parsedWeb = try parser.parse(arguments: ["--web"])
        XCTAssertEqual(CodexBarCLI._decodeSourceModeForTesting(from: parsedWeb), .web)
    }

    func test_shouldUseColorRespectsFormatAndFlags() {
        XCTAssertFalse(CodexBarCLI.shouldUseColor(noColor: true, format: .text))
        XCTAssertFalse(CodexBarCLI.shouldUseColor(noColor: false, format: .json))
    }

    func test_kiloUsageTextNotesShowFallbackOnlyForAutoResolvedToCLI() {
        XCTAssertEqual(CodexBarCLI.usageTextNotes(
            provider: .kilo,
            sourceMode: .auto,
            resolvedSourceLabel: "cli"), ["Using CLI fallback"])
        XCTAssertTrue(CodexBarCLI.usageTextNotes(
            provider: .kilo,
            sourceMode: .api,
            resolvedSourceLabel: "cli").isEmpty)
        XCTAssertTrue(CodexBarCLI.usageTextNotes(
            provider: .codex,
            sourceMode: .auto,
            resolvedSourceLabel: "cli").isEmpty)
    }

    func test_kiloAutoFallbackSummaryIncludesOrderedAttemptDetails() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "kilo.api",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: "Kilo authentication failed (401/403)."),
            ProviderFetchAttempt(
                strategyID: "kilo.cli",
                kind: .cli,
                wasAvailable: true,
                errorDescription: "Kilo CLI session not found."),
        ]

        let summary = CodexBarCLI.kiloAutoFallbackSummary(
            provider: .kilo,
            sourceMode: .auto,
            attempts: attempts)
        let expected = [
            "Kilo auto fallback attempts: api: Kilo authentication failed (401/403).",
            " -> cli: Kilo CLI session not found.",
        ].joined()

        XCTAssertEqual(summary, expected)
    }

    func test_kiloAutoFallbackSummaryIsNilOutsideKiloAutoFailures() {
        let attempts = [
            ProviderFetchAttempt(
                strategyID: "kilo.api",
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: "example"),
        ]

        XCTAssertNil(CodexBarCLI.kiloAutoFallbackSummary(
            provider: .kilo,
            sourceMode: .api,
            attempts: attempts))
        XCTAssertNil(CodexBarCLI.kiloAutoFallbackSummary(
            provider: .codex,
            sourceMode: .auto,
            attempts: attempts))
    }

    func test_sourceModeRequiresWebSupportIsProviderAware() {
        XCTAssertTrue(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .kilo))
        XCTAssertTrue(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .codex))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .kilo))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .grok))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .grok))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .amp))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(.api, provider: .kilo))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .ollama,
            environment: ["OLLAMA_API_KEY": "ollama-test"]))
        XCTAssertTrue(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .codex,
            environment: ["OLLAMA_API_KEY": "ollama-test"]))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .ollama,
            settings: ProviderSettingsSnapshot.make(
                ollama: .init(cookieSource: .off, manualCookieHeader: nil))))
    }
}
