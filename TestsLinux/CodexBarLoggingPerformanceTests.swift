import Logging
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexBarLoggingPerformanceTests {
    @Test
    func `filtered log messages are not evaluated`() {
        let probe = LogEvaluationProbe()
        let logger = CodexBarLogger(minimumLevel: .info) { _, message, _ in
            probe.loggedMessages.append(message)
        }

        logger.debug(probe.expensiveMessage())

        #expect(probe.evaluations == 0)
        #expect(probe.loggedMessages.isEmpty)

        logger.info(probe.expensiveMessage())

        #expect(probe.evaluations == 1)
        #expect(probe.loggedMessages == ["evaluated"])
    }

    @Test
    func `disabled file logging does not format metadata`() {
        let sink = FileLogSink()
        var handler = FileLogHandler(label: "test", sink: sink)
        let probe = LogEvaluationProbe()
        handler[metadataKey: "expensive"] = .stringConvertible(ExpensiveMetadataValue {
            probe.evaluations += 1
        })

        handler.log(event: LogEvent(
            level: .info,
            message: "hello",
            metadata: nil,
            source: "test",
            file: #filePath,
            function: #function,
            line: #line))

        #expect(probe.evaluations == 0)
    }

    @Test
    func `redactor leaves ordinary log lines unchanged`() {
        let line = "CodexBar starting version=1.2.3 build=456"

        #expect(LogRedactor.redact(line) == line)
    }

    @Test
    func `redactor still redacts sensitive log lines`() {
        let line = "Authorization: Bearer secret-token\nContact: user@example.com"
        let redacted = LogRedactor.redact(line)

        #expect(redacted.contains("secret-token") == false)
        #expect(redacted.contains("user@example.com") == false)
        #expect(redacted.contains("Authorization: <redacted>"))
        #expect(redacted.contains("<redacted-email>"))
    }
}

private final class LogEvaluationProbe: @unchecked Sendable {
    var evaluations = 0
    var loggedMessages: [String] = []

    func expensiveMessage() -> String {
        self.evaluations += 1
        return "evaluated"
    }
}

private struct ExpensiveMetadataValue: CustomStringConvertible, Sendable {
    let onRender: @Sendable () -> Void

    var description: String {
        self.onRender()
        return "rendered"
    }
}
