import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ShellCommandOutputLimitTests {
    @Test(arguments: [4096, 1048576, 1048577, 8388608])
    func `shell discovery rejects oversized output without returning a truncated path`(byteCount: Int) throws {
        let output = ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", "head -c \(byteCount) /dev/zero"],
            timeout: 10)

        if byteCount > 1024 * 1024 {
            #expect(output == nil)
        } else {
            let data = try #require(output)
            #expect(data == Data(repeating: 0, count: byteCount))
        }
    }

    @Test
    func `shell discovery drains verbose stderr while preserving stdout`() throws {
        let output = ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", "head -c 8388608 /dev/zero >&2; printf '/synthetic/bin'"],
            timeout: 10)

        #expect(output == Data("/synthetic/bin".utf8))
    }
}
