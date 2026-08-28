#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

private actor CookieImporterOverrideBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            guard self.continuations.count == 2 else { return }

            let continuations = self.continuations
            self.continuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

struct CookieImporterOverrideIsolationTests {
    @Test
    func `cookie importer overrides stay isolated across concurrent tasks`() async throws {
        let expectedLabels = ["first", "second"]
        let barrier = CookieImporterOverrideBarrier()

        let observedLabels = try await withThrowingTaskGroup(
            of: String.self,
            returning: Set<String>.self)
        { group in
            for label in expectedLabels {
                group.addTask {
                    try await AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                        AlibabaCodingPlanCookieImporter.SessionInfo(cookies: [], sourceLabel: label)
                    } operation: {
                        await barrier.wait()
                        return try AlibabaCodingPlanCookieImporter.importSession(
                            browserDetection: BrowserDetection()).sourceLabel
                    }
                }
            }

            var labels: Set<String> = []
            for try await label in group {
                labels.insert(label)
            }
            return labels
        }

        #expect(observedLabels == Set(expectedLabels))
    }

    @Test
    func `perplexity overrides bypass the shared import cache`() async throws {
        PerplexityCookieImporter.invalidateImportSessionCache()
        defer { PerplexityCookieImporter.invalidateImportSessionCache() }

        let first = try await PerplexityCookieImporter.withImportSessionsOverrideForTesting { _, _ in
            [PerplexityCookieImporter.SessionInfo(cookies: [], sourceLabel: "first")]
        } operation: {
            try PerplexityCookieImporter.importSessions().map(\.sourceLabel)
        }
        let second = try await PerplexityCookieImporter.withImportSessionsOverrideForTesting { _, _ in
            [PerplexityCookieImporter.SessionInfo(cookies: [], sourceLabel: "second")]
        } operation: {
            try PerplexityCookieImporter.importSessions().map(\.sourceLabel)
        }

        #expect(first == ["first"])
        #expect(second == ["second"])
    }
}
#endif
