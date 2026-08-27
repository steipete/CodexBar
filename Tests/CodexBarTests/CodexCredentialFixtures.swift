import Foundation
import Testing
@testable import CodexBarCore

/// Each test owns one root. No process-wide authorization, including between parallel test cases.
struct CodexCredentialFixtures: TestTrait, SuiteTrait, TestScoping {
    @TaskLocal private static var currentRoot: URL?

    static var root: URL {
        guard let currentRoot else { preconditionFailure("Add CodexCredentialFixtures to this test or suite") }
        return currentRoot
    }

    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-credential-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.$currentRoot.withValue(root) {
            try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
                try await OpenAIDashboardCacheStore.$cacheURLOverride.withValue(
                    root.appendingPathComponent("openai-dashboard.json"))
                {
                    try await function()
                }
            }
        }
    }
}
