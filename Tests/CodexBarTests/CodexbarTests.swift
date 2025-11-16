import XCTest
@testable import CodexBar

final class CodexBarTests: XCTestCase {
    func testIconRendererProducesTemplateImage() {
        let image = IconRenderer.makeIcon(primaryRemaining: 50, weeklyRemaining: 75, stale: false)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testUsageFetcherParsesLatestTokenCount() async throws {
        let tmp = try XCTUnwrap(FileManager.default.url(for: .itemReplacementDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                        create: true))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessions = tmp.appendingPathComponent("sessions/2025/11/16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let event: [String: Any] = [
            "timestamp": "2025-11-16T18:00:00.000Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": NSNull(),
                "rate_limits": [
                    "primary": [
                        "used_percent": 25.0,
                        "window_minutes": 300,
                        "resets_at": 1_763_320_800,
                    ],
                    "secondary": [
                        "used_percent": 60.0,
                        "window_minutes": 10_080,
                        "resets_at": 1_763_608_000,
                    ],
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: event)
        let file = sessions.appendingPathComponent("rollout-2025-11-16T18-00-00.jsonl")
        try data.appendedNewline().write(to: file)

        // Make sure this file is the newest.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let snapshot = try await fetcher.loadLatestUsage()

        XCTAssertEqual(snapshot.primary.usedPercent, 25.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.secondary.usedPercent, 60.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.primary.windowMinutes, 300)
        XCTAssertEqual(snapshot.secondary.windowMinutes, 10_080)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let expectedDate = formatter.date(from: "2025-11-16T18:00:00.000Z")
        XCTAssertEqual(snapshot.updatedAt, expectedDate)
    }

    func testUsageFetcherErrorsWhenNoTokenCount() async {
        let tmp = try! FileManager.default.url(for: .itemReplacementDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                               create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessions = tmp.appendingPathComponent("sessions/2025/11/16", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let file = sessions.appendingPathComponent("rollout-2025-11-16T10-00-00.jsonl")
        try? "{\"timestamp\":\"2025-11-16T10:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"other\"}}\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        await XCTAssertThrowsErrorAsync(try await fetcher.loadLatestUsage()) { error in
            guard case UsageError.noRateLimitsFound = error else {
                XCTFail("Expected noRateLimitsFound, got \(error)")
                return
            }
        }
    }
}

// MARK: - Async throw helper

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private extension Data {
    func appendedNewline() -> Data {
        var result = self
        result.append(0x0A)
        return result
    }
}
