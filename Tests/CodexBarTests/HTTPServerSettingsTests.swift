import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct HTTPServerSettingsTests {
    @Test
    func `defaults are local and disabled and token never enters arguments`() {
        var config = HTTPServerConfiguration()
        #expect(!config.enabled)
        #expect(config.host == "127.0.0.1")
        #expect(config.identity == "redacted")
        config.token = HTTPServerConfiguration.generateToken()
        #expect(config.token.count == 64)
        #expect(config.validationError == nil)
        #expect(!config.arguments.contains(config.token))
        #expect(!config.arguments.contains("--dashboard-token"))
        #expect(config.arguments.contains("redacted"))
    }

    @Test
    func `validation preserves CLI address port timing and remote consent rules`() {
        var config = HTTPServerConfiguration()
        config.token = "synthetic-token"
        for host in ["localhost", "127.0.0.1", "127.10.1.2"] {
            config.host = host
            #expect(config.validationError == nil)
        }
        config.host = "100.64.0.1"
        #expect(config.validationError != nil)
        config.allowPlainHTTP = true
        #expect(config.validationError == nil)
        for host in ["", "127.0.0.1.evil", "127.01.0.1", "::1", "999.1.1.1", "+1.2.3.4"] {
            config.host = host
            #expect(config.validationError != nil)
        }
        config.host = "0.0.0.0"
        #expect(config.validationError == nil)
        config.port = 0
        #expect(config.validationError != nil)
        config.port = 65536
        #expect(config.validationError != nil)
        config.port = 8080
        config.requestTimeout = .infinity
        #expect(config.validationError != nil)
        config.requestTimeout = 0
        config.refreshInterval = -1
        #expect(config.validationError != nil)
        config.refreshInterval = 0
        #expect(config.validationError == nil)
        config.token = " "
        #expect(config.validationError != nil)
    }

    @Test
    func `local settings round trip with owner only permissions and never enter provider config`() throws {
        let directory = self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("http-server.json")
        var config = HTTPServerConfiguration()
        config.token = "synthetic-token"
        try config.save(to: url)
        #expect(try HTTPServerConfiguration.load(from: url) == config)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let exported = try CodexBarConfig(providers: []).encodedData()
        #expect(String(data: exported, encoding: .utf8)?.contains(config.token) == false)
    }

    @Test
    func `disabled startup and invalid remote settings never launch a helper`() async {
        let directory = self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("http-server.json")
        let controller = HTTPServerController(configURL: url, helperURL: directory.appendingPathComponent("missing"))
        await controller.startSaved()
        #expect(controller.status == "Stopped")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var config = HTTPServerConfiguration()
        config.enabled = true
        config.host = "0.0.0.0"
        config.token = "synthetic-token"
        await controller.apply(config)
        #expect(controller.status.contains("warning"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func `managed child receives token privately restarts and stops on disable`() async throws {
        let directory = self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("helper")
        let receipt = directory.appendingPathComponent("receipt")
        // Synthetic helper binds no ports, reads no provider data, and terminates on SIGTERM.
        let script = """
        #!/bin/sh
        test "$CODEXBAR_DASHBOARD_TOKEN" = "synthetic-token" || exit 17
        case "$*" in *synthetic-token*) exit 18;; esac
        echo $$ >> '\(receipt.path)'
        echo 'CodexBar server listening on http://127.0.0.1:8080' >&2
        exec /bin/sleep 60
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let controller = HTTPServerController(
            configURL: directory.appendingPathComponent("http-server.json"), helperURL: helper)
        var config = HTTPServerConfiguration()
        config.enabled = true
        config.token = "synthetic-token"
        try config.save(to: directory.appendingPathComponent("http-server.json"))
        await controller.startSaved()
        try await self.waitForStatus("Running", controller)
        #expect(controller.runningURL == "http://127.0.0.1:8080/")
        await controller.apply(config)
        try await self.waitForStatus("Running", controller)
        config.enabled = false
        await controller.apply(config)
        #expect(controller.status == "Stopped")
        #expect(controller.runningURL == nil)
        config.enabled = true
        await controller.apply(config)
        try await self.waitForStatus("Running", controller)
        await controller.stopForTermination()?.value
        await controller.apply(config)
        #expect(controller.runningURL == nil)
        let pids = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 3)
        for pid in pids {
            #expect(kill(pid, 0) == -1)
        }
    }

    @Test
    func `startup failures surface and corrupt settings remain untouched`() async throws {
        let directory = self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("http-server.json")
        try Data("invalid".utf8).write(to: url)
        let controller = HTTPServerController(configURL: url, helperURL: directory.appendingPathComponent("missing"))
        await controller.startSaved()
        #expect(controller.status.contains("Could not read"))
        #expect(try Data(contentsOf: url) == Data("invalid".utf8))
        var config = HTTPServerConfiguration()
        config.enabled = true
        config.token = "synthetic-token"
        await controller.apply(config)
        #expect(controller.status.contains("Could not launch"))
        #expect(controller.runningURL == nil)
        let exited = HTTPServerController(configURL: url, helperURL: URL(fileURLWithPath: "/usr/bin/false"))
        await exited.apply(config)
        try await self.waitForStatus("Server exited (status 1). Check the bind address and port.", exited)
        #expect(exited.runningURL == nil)
    }

    @Test
    func `quitting during restart retains the pending child shutdown`() async throws {
        let directory = self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("helper")
        let receipt = directory.appendingPathComponent("pid")
        try """
        #!/bin/sh
        trap '' TERM
        echo $$ > '\(receipt.path)'
        echo 'CodexBar server listening on http://127.0.0.1:8080' >&2
        exec /bin/sleep 60
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let controller = HTTPServerController(
            configURL: directory.appendingPathComponent("http-server.json"), helperURL: helper)
        var config = HTTPServerConfiguration()
        config.enabled = true
        config.token = "synthetic-token"
        await controller.apply(config)
        try await self.waitForStatus("Running", controller)
        let pid = try #require(Int32(String(contentsOf: receipt, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        let restart = Task { await controller.apply(config) }
        try await self.waitForStatus("Stopping…", controller)
        let shutdown = controller.stopForTermination()
        #expect(shutdown != nil)
        await shutdown?.value
        #expect(kill(pid, 0) == -1)
        await restart.value
        #expect(controller.status == "Stopped")
        #expect(controller.runningURL == nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HTTPServerTests-\(UUID().uuidString)")
    }

    private func waitForStatus(_ expected: String, _ controller: HTTPServerController) async throws {
        for _ in 0..<200 {
            if controller.status == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.status == expected)
    }
}
