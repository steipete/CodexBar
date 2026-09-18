import Darwin
import Foundation
import Testing
@testable import CodexBar

struct GrokLoginRunnerTests {
    @Test
    func `login runner uses device-auth and reports the verification URL`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-grok-login-runner-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let grokCLI = binDir.appendingPathComponent("grok")
        let script = """
        #!/bin/sh
        if [ "$1" != "login" ] || [ "$2" != "--device-auth" ]; then
          printf 'unexpected:%s\\n' "$*" >&2
          exit 2
        fi
        if [ -n "$GROK_OAUTH_TOKEN" ]; then
          printf 'token-leaked\\n' >&2
          exit 3
        fi
        printf 'GROK_HOME=%s\\n' "$GROK_HOME"
        printf 'To sign in, open this URL in your browser:\\n'
        printf 'https://accounts.x.ai/activate?user_code=ABCD-1234\\n'
        printf 'Waiting for authorization...\\n'
        /bin/sleep 1.2
        """
        try script.write(to: grokCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokCLI.path)

        let progress = ProgressBox()
        let result = await GrokLoginRunner.run(
            homePath: "/tmp/codexbar-managed-grok-home",
            timeout: 5,
            environment: [
                "GROK_CLI_PATH": grokCLI.path,
                "GROK_OAUTH_TOKEN": "should-not-leak",
                "PATH": binDir.path,
            ],
            loginPATH: nil,
            onProgress: { text in progress.record(text) })

        #expect(result.outcome == .success)
        #expect(result.output.contains("GROK_HOME=/tmp/codexbar-managed-grok-home"))
        #expect(result.output.contains("https://accounts.x.ai/activate?user_code=ABCD-1234"))
        #expect(progress.value?.contains("https://accounts.x.ai/activate?user_code=ABCD-1234") == true)
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?

        var value: String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.text
        }

        func record(_ text: String) {
            self.lock.lock()
            self.text = text
            self.lock.unlock()
        }
    }
}
