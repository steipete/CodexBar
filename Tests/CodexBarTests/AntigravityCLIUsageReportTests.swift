import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension AntigravityCLIHTTPSFetchStrategyTests {
    @Test
    func `CLI report parses structured quotas`() throws {
        let json = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "response": "Synthetic quota report",
          "duration_seconds": 0,
          "num_turns": 0,
          "usage": {
            "input_tokens": 0,
            "output_tokens": 0,
            "thinking_tokens": 0,
            "cache_read_tokens": 0,
            "total_tokens": 0
          },
          "command": {
            "name": "usage",
            "data": {
              "description": "Models share limits",
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Gemini models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "description": "Weekly limit",
                      "window": "weekly",
                      "remaining_fraction": 0.86,
                      "reset_time": "2026-09-17T18:40:27Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "description": "5-hour limit",
                      "window": "5h",
                      "remaining_fraction": 0.95,
                      "reset_time": "2026-09-13T03:48:04Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "description": "3p models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "description": "Weekly limit",
                      "window": "weekly",
                      "remaining_fraction": 0.89,
                      "reset_time": "2026-09-17T02:38:46Z"
                    },
                    {
                      "id": "3p-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 1.0,
                      "reset_time": "2026-09-13T05:29:19Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let snapshot = try AntigravityStatusProbe.parseCLIUsageReport(Data(json.utf8))
        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary != nil)
        #expect(usage.secondary != nil)
        #expect(usage.extraRateWindows?.count == 4)
    }

    @Test(arguments: ["ERROR", "PENDING", "success"])
    func `CLI report requires successful command status`(status: String) throws {
        let report = try Self.reportJSON(status: status)
        #expect(throws: AntigravityStatusProbeError.parseFailed("Unsuccessful CLI usage report")) {
            try AntigravityStatusProbe.parseCLIUsageReport(Data(report.utf8))
        }
    }

    @Test
    func `CLI report rejects unrelated commands and unavailable quota`() throws {
        #expect(throws: AntigravityStatusProbeError.parseFailed("Unsuccessful CLI usage report")) {
            try AntigravityStatusProbe.parseCLIUsageReport(Data(Self.reportJSON(command: "models").utf8))
        }
        for report in try [Self.reportJSON(fraction: nil), Self.reportJSON(disabled: true)] {
            #expect(throws: AntigravityStatusProbeError.parseFailed("CLI usage report has no known quota")) {
                try AntigravityStatusProbe.parseCLIUsageReport(Data(report.utf8))
            }
        }
        #expect(throws: DecodingError.self) {
            try AntigravityStatusProbe.parseCLIUsageReport(Data("not-json".utf8))
        }
    }

    @Test
    func `verified HTTPS result keeps its identity without running print`() async throws {
        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let expected = strategy.makeResult(usage: self.makeUsage(accountEmail: "owner@example.com"), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: self.makeFetchContext(),
            legacyFetch: { expected },
            reportFetch: {
                Issue.record("A successful HTTPS response must not be replaced")
                return expected
            })
        #expect(result.usage.identity?.accountEmail == "owner@example.com")
    }

    @Test(arguments: [ProviderSourceMode.auto, .cli])
    func `unselected fetch falls back to identity free print`(mode: ProviderSourceMode) async throws {
        let expected = AntigravityCLIHTTPSFetchStrategy().makeResult(
            usage: self.makeUsage(accountEmail: nil), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: self.makeFetchContext(sourceMode: mode),
            legacyFetch: { throw AntigravityStatusProbeError.apiError("usage endpoint unavailable") },
            reportFetch: { expected })
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.sourceLabel == "cli")
    }

    @Test
    func `selected and injected auto accounts exclude identity free print visibly`() async {
        let injectedKey = AntigravityOAuthCredentialsStore.environmentCredentialsKey
        let contexts = [
            self.makeFetchContext(selectedTokenAccountID: UUID(), env: self.accountEnv(email: "selected@example.com")),
            self.makeFetchContext(env: self.accountEnv(email: "injected@example.com")),
            self.makeFetchContext(env: [injectedKey: "malformed"]),
            self.makeFetchContext(env: [injectedKey: ""]),
        ]
        for context in contexts {
            await #expect(throws: AntigravityStatusProbeError.identityFreeReportExcluded(
                underlyingDescription: "Antigravity quota request timed out."))
            {
                try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                    context: context,
                    legacyFetch: { throw AntigravityStatusProbeError.timedOut },
                    reportFetch: {
                        Issue.record("Print cannot prove the requested OAuth account")
                        throw AntigravityStatusProbeError.notRunning
                    })
            }
        }
    }

    @Test
    func `excluded identity free print keeps the underlying failure and names the skip`() async {
        let context = self.makeFetchContext(
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "s@example.com"))
        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                context: context,
                legacyFetch: { throw AntigravityStatusProbeError.apiError("HTTP 500") },
                reportFetch: {
                    Issue.record("Print cannot prove the requested OAuth account")
                    throw AntigravityStatusProbeError.notRunning
                })
            Issue.record("The excluded report corner must throw")
        } catch let error as AntigravityStatusProbeError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("HTTP 500"))
            #expect(description.contains("Identity-free CLI usage report skipped"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test(arguments: [AntigravityStatusProbeError.notRunning, .missingCSRFToken])
    func `unavailable legacy failure stays a placeholder when print is excluded`(
        error: AntigravityStatusProbeError) async
    {
        let context = self.makeFetchContext(
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "s@example.com"))
        let earlierFailure = AntigravityStatusProbeError.apiError("earlier app failure")
        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                context: context,
                legacyFetch: { throw error },
                reportFetch: {
                    Issue.record("Print cannot prove the requested OAuth account")
                    throw AntigravityStatusProbeError.timedOut
                })
            Issue.record("The unavailable CLI source must fail")
        } catch let caught {
            #expect(caught as? AntigravityStatusProbeError == error)
            let surfaced = AntigravityProviderDescriptor.resolveFallbackError(earlierFailure, caught)
            #expect(surfaced as? AntigravityStatusProbeError == earlierFailure)
        }
    }

    @Test
    func `explicit CLI mode retains its source authority`() async throws {
        let context = self.makeFetchContext(
            sourceMode: .cli, selectedTokenAccountID: UUID(), env: self.accountEnv(email: "selected@example.com"))
        let expected = AntigravityCLIHTTPSFetchStrategy().makeResult(
            usage: self.makeUsage(accountEmail: nil), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: context,
            legacyFetch: { throw AntigravityStatusProbeError.timedOut },
            reportFetch: { expected })
        #expect(result.usage.identity?.accountEmail == nil)
    }

    @Test
    func `cancelled HTTPS work never starts print fallback`() async {
        await #expect(throws: CancellationError.self) {
            try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                context: self.makeFetchContext(),
                legacyFetch: { throw CancellationError() },
                reportFetch: {
                    Issue.record("Cancellation must stop the provider pipeline")
                    throw AntigravityStatusProbeError.notRunning
                })
        }
    }

    @Test(arguments: ["1.1.11", "1.2.2", "2.0.0"])
    func `print subprocess uses the pinned executable and supported command`(version: String) async throws {
        let report = try Self.reportJSON()
        let fixture = try Self.printExecutable("""
        [ "$*" = '-p /usage --output-format json --print-timeout 90s' ] || exit 9
        [ "$PWD" != "$HOME" ] || exit 10
        [ -z "${ANTIGRAVITY_OAUTH_CREDENTIALS_JSON+x}" ] || exit 11
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let binary = try #require(BinaryLocator.resolveAntigravityBinary(env: fixture.environment))
        #expect(binary == fixture.binary.path)
        var environment = fixture.environment
        environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey] = "synthetic-app-owned-credential"
        let result = try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
            binary: binary, environment: environment)
        #expect(environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey] ==
            "synthetic-app-owned-credential")
        #expect(abs((result.usage.primary?.usedPercent ?? -1) - 40) < 0.001)
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.usage.identity?.loginMethod == nil)
    }

    @Test(arguments: ["1.1.10", "1.0.99", "running", "", "1.2.2-preview", "1.2.2.3", "+1.2.2"])
    func `unsupported versions never execute a print prompt`(version: String) async throws {
        let fixture = try Self.printExecutable("touch \"$HOME/unexpected-print\"; exit 9", version: version)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await #expect(throws: AntigravityStatusProbeError
            .parseFailed("CLI usage reports require agy 1.1.11 or later"))
        {
            try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
                binary: fixture.binary.path, environment: fixture.environment)
        }
        #expect(!FileManager.default
            .fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-print").path))
    }

    @Test
    func `print failure does not expose stderr`() async throws {
        let fixture = try Self.printExecutable("printf 'synthetic-private-diagnostic' >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await #expect(throws: AntigravityStatusProbeError.parseFailed("CLI usage report failed")) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
                binary: fixture.binary.path, environment: fixture.environment)
        }
    }

    @Test
    func `oversized print output is rejected before decoding`() async throws {
        let fixture = try Self.printExecutable("/usr/bin/head -c 1100000 /dev/zero")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await #expect(throws: AntigravityStatusProbeError.parseFailed("CLI usage report failed")) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
                binary: fixture.binary.path, environment: fixture.environment)
        }
    }

    @Test(arguments: [true, false])
    func `print timeout terminates its process`(versionKnown: Bool) async throws {
        let fixture = try Self.printExecutable(
            "echo $$ > \"$HOME/pid.tmp\"; /bin/mv \"$HOME/pid.tmp\" \"$HOME/pid\"; exec /bin/sleep 10",
            version: versionKnown ? "1.2.2" : nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await #expect(throws: AntigravityStatusProbeError.timedOut) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
                binary: fixture.binary.path, environment: fixture.environment, timeout: 3)
        }
        try Self.expectPrintProcessExited(in: fixture.directory)
    }

    @Test(arguments: [true, false])
    func `print cancellation terminates its process`(versionKnown: Bool) async throws {
        let fixture = try Self.printExecutable(
            "echo $$ > \"$HOME/pid.tmp\"; /bin/mv \"$HOME/pid.tmp\" \"$HOME/pid\"; exec /bin/sleep 10",
            version: versionKnown ? "1.2.2" : nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task {
            try await AntigravityCLIHTTPSFetchStrategy().fetchPrintUsage(
                binary: fixture.binary.path, environment: fixture.environment, timeout: 5)
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(3)
        var observedPID: Int32?
        while Date() < deadline {
            if let text = try? String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0, kill(pid, 0) == 0
            {
                observedPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // File creation precedes its contents; cancellation must wait for a published, running process.
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(observedPID)
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: [
        ("1.1.28", true),
        ("1.2.0", true),
        ("1.2.1", true),
        ("1.2.2", false),
        ("1.2.4", false),
        ("1.10.0", false),
        ("2.0.0", false),
        ("1.2.2-preview", true),
        ("", true),
    ])
    func `only CSRF gated agy versions skip the managed spawn`(version: String, spawns: Bool) {
        let parsed = AntigravityCLIHTTPSFetchStrategy.parseVersion(version)
        #expect(AntigravityCLIHTTPSFetchStrategy.spawnCanReachLocalServer(version: parsed) == spawns)
    }

    @Test
    func `CSRF gated agy never starts a managed spawn`() async {
        await #expect(throws: AntigravityStatusProbeError
            .apiError("agy 1.2.2 or later requires a local CSRF token"))
        {
            try await AntigravityCLIHTTPSFetchStrategy.fetchBySpawningIfReachable(version: (1, 2, 2)) {
                Issue.record("A tokenless spawn cannot become ready on agy 1.2.2 or later")
                throw AntigravityStatusProbeError.notRunning
            }
        }
    }

    @Test(arguments: ["", "1.2.1"])
    func `older or unknown agy keeps the managed spawn`(version: String) async throws {
        let expected = AntigravityCLIHTTPSFetchStrategy().makeResult(
            usage: self.makeUsage(accountEmail: "owner@example.com"), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchBySpawningIfReachable(
            version: AntigravityCLIHTTPSFetchStrategy.parseVersion(version))
        {
            expected
        }
        #expect(result.usage.identity?.accountEmail == "owner@example.com")
    }

    @Test
    func `CSRF gated CLI fetch reaches the print report without spawning`() async throws {
        let report = try Self.reportJSON()
        let fixture = try Self.printExecutable("""
        if [ "${1:-}" != -p ]; then exit 9; fi
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """, version: "1.2.2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await AntigravityCLIHTTPSFetchStrategy().fetch(
            self.makeFetchContext(sourceMode: .cli, env: fixture.environment),
            warmDependencies: Self.noWarmSession(),
            spawnFetch: { _, _, _, _ in
                Issue.record("A CSRF-gated CLI must not touch the managed session")
                throw AntigravityStatusProbeError.timedOut
            })
        #expect(abs((result.usage.primary?.usedPercent ?? -1) - 40) < 0.001)
    }

    @Test(arguments: ["", "1.2.1"])
    func `full fetch retains managed spawning for older and unknown versions`(version: String) async throws {
        let fixture = try Self.printExecutable("exit 19", version: version)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let expected = strategy.makeResult(
            usage: self.makeUsage(accountEmail: "fixture@example.com"),
            sourceLabel: "fixture-spawn")
        let result = try await strategy.fetch(
            self.makeFetchContext(sourceMode: .cli, env: fixture.environment),
            warmDependencies: Self.noWarmSession(),
            spawnFetch: { binary, _, _, expectedEmail in
                #expect(binary == fixture.binary.path)
                #expect(expectedEmail == nil)
                return expected
            })
        #expect(result.sourceLabel == "fixture-spawn")
    }

    @Test(arguments: [false, true])
    func `CSRF skip cannot enable identity free reports for scoped Auto accounts`(selected: Bool) async throws {
        let fixture = try Self.printExecutable("echo invoked > \"$HOME/printed\"; exit 19")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var environment = fixture.environment
        if !selected {
            environment.merge(self.accountEnv(email: "fixture@example.com")) { _, new in new }
        }
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: selected ? UUID() : nil,
            env: environment)
        // The identity-free report stays excluded and the exclusion is visible:
        // the surfaced error keeps the CSRF failure and names the skipped report.
        await #expect(throws: AntigravityStatusProbeError
            .identityFreeReportExcluded(
                underlyingDescription: "Antigravity API error: agy 1.2.2 or later requires a local CSRF token"))
        {
            try await AntigravityCLIHTTPSFetchStrategy().fetch(
                context,
                warmDependencies: Self.noWarmSession(),
                spawnFetch: { _, _, _, _ in
                    Issue.record("A CSRF-gated CLI must not touch the managed session")
                    throw AntigravityStatusProbeError.timedOut
                })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("printed").path))
    }

    @Test
    func `warm usage bypasses version probing and print subprocesses`() async throws {
        let fixture = try Self.printExecutable("echo invoked > \"$HOME/invoked\"; exit 19", version: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let snapshot = try AntigravityStatusProbe.parseCLIUsageReport(Data(Self.reportJSON().utf8))
        let process = AntigravityStatusProbe.ProcessInfoResult(
            pid: 9901,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "",
            commandLine: fixture.binary.path)
        let result = try await AntigravityCLIHTTPSFetchStrategy().fetch(
            self.makeFetchContext(sourceMode: .cli, env: fixture.environment),
            warmDependencies: makeAntigravityWarmDependencies(
                processInfos: { _ in [process] },
                listeningPorts: { _, _ in [56789] },
                fetchSnapshot: { _, _ in snapshot }),
            spawnFetch: { _, _, _, _ in
                Issue.record("Reusable external usage must not start a managed session")
                throw AntigravityStatusProbeError.timedOut
            })
        #expect(abs((result.usage.primary?.usedPercent ?? -1) - 40) < 0.001)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("invoked").path))
    }

    private static func noWarmSession() -> AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies {
        makeAntigravityWarmDependencies(
            processInfos: { _ in [] },
            listeningPorts: { _, _ in
                Issue.record("Empty discovery must not inspect ports")
                return []
            },
            fetchSnapshot: { _, _ in
                Issue.record("Empty discovery must not fetch a server")
                throw AntigravityStatusProbeError.notRunning
            })
    }

    private static func expectPrintProcessExited(in directory: URL) throws {
        let text = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    private static func printExecutable(_ body: String, version: String? = "1.2.2") throws
    -> (directory: URL, binary: URL, environment: [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("agy")
        var script = "#!/bin/sh\nset -eu\n"
        if let version {
            try version.write(to: directory.appendingPathComponent("version"), atomically: true, encoding: .utf8)
            script += "if [ \"${1:-}\" = --version ]; then exec /bin/cat \"$HOME/version\"; fi\n"
        }
        try (script + body + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (
            directory,
            binary,
            ["HOME": directory.path, "PATH": "/usr/bin:/bin", "ANTIGRAVITY_CLI_PATH": binary.path])
    }

    private static func reportJSON(
        status: String = "SUCCESS",
        command: String = "usage",
        fraction: Double? = 0.6,
        disabled: Bool = false) throws -> String
    {
        var bucket: [String: Any] = ["id": "gemini-5h", "name": "Five Hour Limit Remaining", "disabled": disabled]
        if let fraction { bucket["remaining_fraction"] = fraction }
        let report: [String: Any] = [
            "status": status,
            "response": "Synthetic quota report",
            "command": ["name": command, "data": ["groups": [["name": "Gemini Models", "buckets": [bucket]]]]],
        ]
        return try #require(String(data: JSONSerialization.data(withJSONObject: report), encoding: .utf8))
    }
}
