import Foundation
import XCTest
@testable import CodexBarCore

final class AuditLoggerTests: XCTestCase {
    func test_sanitizeForSummary_normalizesHomePathsAndRedactsURLIdentifiers() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let event = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 1_744_000_000),
            category: .secret,
            action: "file.auth_json.read",
            target: "https://claude.ai/api/organizations/fdcaffd7-1712-4028-b00f-0acdb6ed15fd/usage",
            risk: .sensitive,
            metadata: [
                "path": "\(home)/.codex/auth.json",
                "cache_path": "\(home)/Library/Application Support/CodexBar/managed-codex-homes/E9DAE246-F251-4B46-A36A-E652B135D4FB/log",
            ],
            context: GovernanceContext(flow: "governance", detail: "\(home)/tmp/check"))

        let sanitized = AuditLogger.sanitizeForSummary(event)

        XCTAssertEqual(sanitized.metadata["path"], "~/.codex/auth.json")
        XCTAssertEqual(
            sanitized.metadata["cache_path"],
            "~/Library/Application Support/CodexBar/managed-codex-homes/<id>/log")
        XCTAssertEqual(
            sanitized.target,
            "https://claude.ai/api/organizations/<id>/usage")
        XCTAssertEqual(sanitized.context?.detail, "~/tmp/check")
    }

    func test_sanitizeForSummary_keepsSecretPresenceFlagsButNotSecretValues() {
        let event = AuditEvent(
            category: .network,
            action: "request.completed",
            target: "https://chatgpt.com/backend-api/wham/usage",
            risk: .sensitive,
            metadata: [
                "header_authorization": "1",
                "header_cookie": "0",
                "status_code": "200",
            ])

        let sanitized = AuditLogger.sanitizeForSummary(event)

        XCTAssertEqual(sanitized.metadata["header_authorization"], "1")
        XCTAssertEqual(sanitized.metadata["header_cookie"], "0")
        XCTAssertEqual(sanitized.metadata["status_code"], "200")
    }

    func test_sanitizeText_redactsIdentifiersInsideEmbeddedURLAndHomePathFragments() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = """
        request failed for https://claude.ai/api/organizations/fdcaffd7-1712-4028-b00f-0acdb6ed15fd/usage \
        while reading \(home)/Library/Application Support/CodexBar/managed-codex-homes/E9DAE246-F251-4B46-A36A-E652B135D4FB/log (permission denied)
        """

        let sanitized = AuditPrivacySanitizer.sanitizeText(text)

        XCTAssertTrue(sanitized.contains("https://claude.ai/api/organizations/<id>/usage"))
        XCTAssertTrue(
            sanitized.contains(
                "~/Library/Application Support/CodexBar/managed-codex-homes/<id>/log (permission denied)"))
        XCTAssertFalse(sanitized.contains(home))
        XCTAssertFalse(sanitized.contains("fdcaffd7-1712-4028-b00f-0acdb6ed15fd"))
        XCTAssertFalse(sanitized.contains("E9DAE246-F251-4B46-A36A-E652B135D4FB"))
    }

    func test_summaryState_groupsIdenticalEventsAndTracksTimes() {
        let baseline = Date(timeIntervalSince1970: 1_744_000_000)
        let event = AuditEvent(
            timestamp: baseline,
            category: .secret,
            action: "file.auth_json.read",
            target: "auth.json",
            risk: .sensitive,
            metadata: ["path": "~/.codex/auth.json"])

        var state = GovernanceSummaryState()
        state.record(event)

        let repeated = AuditEvent(
            timestamp: baseline.addingTimeInterval(0.2),
            category: .secret,
            action: "file.auth_json.read",
            target: "auth.json",
            risk: .sensitive,
            metadata: ["path": "~/.codex/auth.json"])
        state.record(repeated)

        let later = AuditEvent(
            timestamp: baseline.addingTimeInterval(2.0),
            category: .secret,
            action: "file.auth_json.read",
            target: "auth.json",
            risk: .sensitive,
            metadata: ["path": "~/.codex/auth.json"])
        state.record(later)

        let different = AuditEvent(
            timestamp: baseline.addingTimeInterval(2.2),
            category: .secret,
            action: "keychain.cache.read",
            target: "cookie.codex",
            risk: .sensitive,
            metadata: ["account": "cookie.codex"])
        state.record(different)

        XCTAssertEqual(state.entries.count, 2)
        XCTAssertEqual(state.entries[0].count, 3)
        XCTAssertEqual(state.entries[0].resource, "~/.codex/auth.json")
        XCTAssertEqual(state.entries[0].firstSeen, baseline)
        XCTAssertEqual(state.entries[0].lastSeen, baseline.addingTimeInterval(2.0))
    }

    func test_summaryRenderer_rendersMarkdownByDayAndRisk() {
        let baseline = Date(timeIntervalSince1970: 1_744_000_000)
        var state = GovernanceSummaryState()
        state.record(AuditEvent(
            timestamp: baseline,
            category: .secret,
            action: "file.auth_json.read",
            target: "auth.json",
            risk: .sensitive,
            metadata: ["path": "~/.codex/auth.json"]))
        state.record(AuditEvent(
            timestamp: baseline.addingTimeInterval(60),
            category: .command,
            action: "subprocess.start",
            target: "security",
            risk: .elevatedRisk,
            metadata: ["binary": "security"]))

        let markdown = GovernanceSummaryRenderer.render(state)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let expectedDay = formatter.string(from: baseline)

        XCTAssertTrue(markdown.contains("# Governance Audit Summary"))
        XCTAssertTrue(markdown.contains("## \(expectedDay)"))
        XCTAssertTrue(markdown.contains("### Elevated-risk events"))
        XCTAssertTrue(markdown.contains("### Sensitive events"))
        XCTAssertTrue(markdown.contains("`~/.codex/auth.json`"))
        XCTAssertTrue(markdown.contains("`security`"))
        XCTAssertTrue(markdown.contains("Status: Expected"))
        XCTAssertTrue(markdown.contains("Needed for normal Codex authentication and usage probing."))
    }

    func test_summaryRenderer_marksUnknownNetworkHostsAsUnexpected() {
        let baseline = Date(timeIntervalSince1970: 1_744_000_000)
        var state = GovernanceSummaryState()
        state.record(AuditEvent(
            timestamp: baseline,
            category: .network,
            action: "request.completed",
            target: "https://unknown-host.example/api/usage",
            risk: .sensitive,
            metadata: ["host": "unknown-host.example"]))

        let markdown = GovernanceSummaryRenderer.render(state)

        XCTAssertTrue(markdown.contains("Status: Unexpected"))
        XCTAssertTrue(markdown.contains("Outside the known set of CodexBar provider and authentication hosts."))
        XCTAssertTrue(markdown.contains("`unknown-host.example`"))
    }

    func test_summaryRenderer_marksSupportedProviderHostsAsExpected() {
        let baseline = Date(timeIntervalSince1970: 1_744_000_000)
        var state = GovernanceSummaryState()
        state.record(AuditEvent(
            timestamp: baseline,
            category: .network,
            action: "request.completed",
            target: "https://app.augmentcode.com/api/session",
            risk: .sensitive,
            metadata: ["host": "app.augmentcode.com"]))

        let markdown = GovernanceSummaryRenderer.render(state)

        XCTAssertTrue(markdown.contains("Status: Expected"))
        XCTAssertTrue(
            markdown.contains(
                "Expected network request to a known CodexBar provider, dashboard, or authentication endpoint."))
        XCTAssertTrue(markdown.contains("`app.augmentcode.com`"))
    }

    func test_summaryRenderer_marksKnownCommandLifecycleAsExpected() {
        let baseline = Date(timeIntervalSince1970: 1_744_000_000)
        var state = GovernanceSummaryState()
        state.record(AuditEvent(
            timestamp: baseline,
            category: .command,
            action: "process.failed",
            target: "unknown-helper",
            risk: .normal,
            metadata: ["binary": "unknown-helper"]))

        let markdown = GovernanceSummaryRenderer.render(state)

        XCTAssertTrue(markdown.contains("Status: Expected"))
        XCTAssertTrue(
            markdown.contains(
                "Expected reporting for helper-process failures encountered during normal app flows."))
        XCTAssertTrue(markdown.contains("`unknown-helper`"))
    }
}
