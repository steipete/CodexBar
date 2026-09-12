import Foundation
import Testing
@testable import CodexBarCore

struct GrokSessionRecoveryTests {
    @Test(arguments: ["{\"result\":{\"token\":\"fake-renewed-token\"}}", "{\"result\":{\"token\":null}}"])
    func `CLI bearer export decodes the nested ACP extension envelope`(result: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokRecoveryRPC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("grok-proof.sh")
        let script = """
        #!/bin/sh
        IFS= read -r initialize_request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r bearer_request
        case "$bearer_request" in
          *'"method":"_x.ai/auth/getBearerToken"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":\(result)}' ;;
          *) printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}' ;;
        esac
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let client = try GrokRPCClient(
            executable: scriptURL.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin", "GROK_CLI_PATH": scriptURL.path],
            initializeTimeoutSeconds: 10,
            requestTimeoutSeconds: 10)
        defer { client.shutdown() }
        try await client.initialize()
        let token = try await client.fetchValidBearerToken()
        #expect(token == (result.contains("null") ? nil : "fake-renewed-token"))
    }
}
