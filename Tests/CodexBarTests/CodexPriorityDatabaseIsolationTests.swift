import Foundation
import Testing
@testable import CodexBarCore

struct CodexPriorityDatabaseIsolationTests {
    @Test
    func `runtime isolation never defaults to the ambient Codex trace database`() {
        let directory = CostUsageScanner.defaultCodexPriorityDatabaseURL().deletingLastPathComponent()
        #expect(directory.lastPathComponent.hasPrefix("codexbar-cost-trace-tests-"))
    }

    @Test(arguments: ["swiftpm-testing-helper", "CodexBarPackageTests", "CodexBarPackageTests.xctest"])
    func `runtime test names isolate traces before consulting the user home`(processName: String) {
        let url = CodexPriorityDatabasePath.defaultURL(
            processName: processName,
            environment: ["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1"],
            codexHome: {
                Issue.record("Test trace resolution consulted the user home")
                return URL(fileURLWithPath: "/synthetic/ambient-codex")
            })
        #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("codexbar-cost-trace-tests-"))
        #expect(url.lastPathComponent == "logs_2.sqlite")
    }

    @Test(arguments: [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
        "TESTING_LIBRARY_VERSION", "SWIFT_TESTING", "SWIFT_TESTING_ENABLED",
        "CODEXBAR_TEST_CODEX_FILE_ISOLATION",
    ])
    func `runtime markers and inherited child isolation never select ambient traces`(marker: String) {
        let url = CodexPriorityDatabasePath.defaultURL(
            processName: "CodexBarCLI",
            environment: [marker: "1", "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1"],
            codexHome: {
                Issue.record("Isolated child trace resolution consulted the user home")
                return URL(fileURLWithPath: "/synthetic/ambient-codex")
            })
        #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("codexbar-cost-trace-tests-"))
    }

    @Test
    func `isolated default is stable and explicit trace fixtures remain authoritative`() {
        let first = CostUsageScanner.defaultCodexPriorityDatabaseURL()
        #expect(CostUsageScanner.resolvedCodexPriorityDatabaseURL(nil) == first)
        #expect(CostUsageScanner.defaultCodexPriorityDatabaseURL() == first)
        let fixture = URL(fileURLWithPath: "/synthetic/priority-trace.sqlite")
        #expect(CostUsageScanner.resolvedCodexPriorityDatabaseURL(fixture) == fixture)
    }

    @Test
    func `ordinary execution retains the system Codex trace path`() {
        let root = URL(fileURLWithPath: "/synthetic/user/.codex", isDirectory: true)
        let url = CodexPriorityDatabasePath.defaultURL(
            processName: "CodexBar",
            environment: ["CODEX_HOME": "/synthetic/override"],
            codexHome: { root })
        #expect(url == root.appendingPathComponent("logs_2.sqlite"))
    }
}
