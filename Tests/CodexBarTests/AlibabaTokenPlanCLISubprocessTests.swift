import Foundation
import Testing
@testable import CodexBarCore

struct AlibabaTokenPlanCLISubprocessTests {
    @Test
    func `real Bailian subprocess receives regional arguments and publishes both quota windows`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-token-plan-cli-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let argumentsPath = directory.appendingPathComponent("arguments.txt")
        let binary = directory.appendingPathComponent("bl")
        let response = #"{"per5HourPercentage":0.25,"per5HourResetTime":1787000400000,"#
            + #""per1WeekPercentage":0.7,"per1WeekResetTime":1787001180000}"#
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsPath.path)'
        printf '%s\\n' '\(response)'
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let now = Date(timeIntervalSince1970: 1_787_000_000)

        let snapshot = try await AlibabaTokenPlanCLIUsageFetcher.fetch(
            region: .internationalPersonal,
            environment: ["PATH": directory.path],
            now: now)
        let arguments = try String(contentsOf: argumentsPath, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        #expect(arguments == AlibabaTokenPlanCLIUsageFetcher.arguments(region: .internationalPersonal))
        #expect(snapshot.fiveHourUsedPercent == 25)
        #expect(snapshot.fiveHourResetsAt == Date(timeIntervalSince1970: 1_787_000_400))
        #expect(snapshot.weeklyUsedPercent == 70)
        #expect(snapshot.weeklyResetsAt == Date(timeIntervalSince1970: 1_787_001_180))
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `CLI probe child process never sees ambient secrets`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-token-plan-cli-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dumpPath = directory.appendingPathComponent("bl-environment.txt")
        let binary = directory.appendingPathComponent("bl")
        try Data("#!/bin/sh\n/usr/bin/env > '\(dumpPath.path)'\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        do {
            _ = try await AlibabaTokenPlanCLIUsageFetcher.fetch(
                region: .chinaMainland,
                environment: [
                    "PATH": directory.path,
                    "HOME": "/Users/fixture",
                    "AWS_SECRET_ACCESS_KEY": "leaked-secret",
                    "ALIBABA_TOKEN_PLAN_COOKIE": "login_aliyunid_ticket=leaked-cookie",
                ])
            Issue.record("Expected the stub bl to fail after dumping its environment")
        } catch AlibabaTokenPlanCLIUsageError.commandFailed {
            // Expected: the stub exits non-zero after writing its environment dump.
        }

        let dumpData = try Data(contentsOf: dumpPath)
        let dump = try #require(String(data: dumpData, encoding: .utf8))
        #expect(dump.contains("PATH="))
        #expect(dump.contains(directory.path))
        #expect(dump.contains("HOME=/Users/fixture"))
        #expect(!dump.contains("AWS_SECRET_ACCESS_KEY"))
        #expect(!dump.contains("leaked-secret"))
        #expect(!dump.contains("leaked-cookie"))
    }

    @Test
    func `cancelled CLI probe surfaces CancellationError instead of commandFailed`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-token-plan-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("bl")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        let task = Task {
            try await AlibabaTokenPlanCLIUsageFetcher.fetch(
                region: .chinaMainland,
                environment: ["PATH": directory.path])
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
