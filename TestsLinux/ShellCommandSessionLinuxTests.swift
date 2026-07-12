import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
@Suite(.serialized)
struct ShellCommandSessionLinuxTests {
    @Test
    func `shell probe launches as a detached session leader`() throws {
        let output = ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", "printf '%s ' \"$$\"; ps -o sid= -p \"$$\""],
            timeout: 5)
        let text = try #require(output.flatMap { String(data: $0, encoding: .utf8) })
        let identifiers = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }

        #expect(identifiers.count == 2)
        guard identifiers.count == 2 else { return }
        #expect(identifiers[0] == identifiers[1])
    }
}
#endif
