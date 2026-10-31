import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KiroUsageRecoveryTests {
    @Test(arguments: [false, true])
    func `usage and context explicitly select V2 through pipes and PTY`(requiresPTY: Bool) async throws {
        let fixture = try Fixture(requiresPTY: requiresPTY)
        defer { fixture.remove() }
        let calls = APICalls()
        let snapshot = try await fixture.probe {
            await calls.record()
            throw KiroUsageLimitsError.requestFailed("Synthetic unavailable API")
        }.fetch()

        #expect(snapshot.creditsUsed == 20)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.contextUsage?.totalPercentUsed == 7.5)
        #expect(snapshot.accountEmail == "kiro@example.com")
        #expect(await calls.callCount == 2)
        for transport in requiresPTY ? ["pipe", "pty"] : ["pipe"] {
            #expect(try fixture.arguments(for: "usage", transport: transport)
                == ["chat", "--no-interactive", "/usage", "--v2"])
            #expect(try fixture.arguments(for: "context", transport: transport)
                == ["chat", "--no-interactive", "/context", "--v2"])
        }
        #expect(try fixture.arguments(for: "whoami", transport: "pipe") == ["whoami"])
    }

    @Test(arguments: UsageFailure.allCases, [0.0, 1470.38])
    func `usable API metrics avoid chats and retain CLI identity`(
        failure: UsageFailure,
        planUsed: Double) async throws
    {
        let fixture = try Fixture(usage: failure.script)
        defer { fixture.remove() }
        let calls = APICalls()
        let limits = Self.limits(planUsed: planUsed)
        let snapshot = try await fixture.probe {
            await calls.record()
            // Recovery must wait for the CLI account probe rather than supplying API-owned identity.
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("whoami.pipe").path))
            return limits
        }.fetch()

        #expect(await calls.callCount == 1)
        #expect(snapshot.planName == "Kiro")
        #expect(snapshot.displayPlanName == "Kiro")
        #expect(snapshot.accountEmail == "kiro@example.com")
        #expect(snapshot.authMethod == "Google")
        #expect(snapshot.hasUsageMetrics)
        #expect(snapshot.creditsUsed == planUsed)
        #expect(snapshot.creditsTotal == 2000)
        #expect(abs(snapshot.creditsPercent - planUsed / 2000 * 100) < 0.0001)
        #expect(snapshot.usageLimits == limits)
        #expect(snapshot.resetsAt == limits.resetsAt)
        #expect(snapshot.overagesStatus == "Disabled")
        #expect(snapshot.bonusCreditsUsed == nil)
        #expect(snapshot.bonusCreditsTotal == nil)
        #expect(snapshot.bonusExpiryDays == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == snapshot.creditsPercent)
        #expect(snapshot.toUsageSnapshot().secondary == nil)
        #expect(snapshot.contextUsage == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usage.pipe").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("context.pipe").path))
    }

    @Test(arguments: UsageFailure.allCases, UnsafeAllowance.allCases)
    func `ambiguous or nonpositive API allowance preserves the original CLI error`(
        failure: UsageFailure,
        allowance: UnsafeAllowance) async throws
    {
        let fixture = try Fixture(usage: failure.script)
        defer { fixture.remove() }
        let calls = APICalls()
        await #expect {
            try await fixture.probe {
                await calls.record()
                return allowance.limits
            }.fetch()
        } throws: { failure.matches($0) }
        #expect(await calls.callCount == 1)
    }

    @Test(arguments: UsageFailure.allCases, APIError.allCases)
    func `API failure or missing CLI credentials preserves the original CLI error`(
        failure: UsageFailure,
        apiError: APIError) async throws
    {
        let fixture = try Fixture(usage: failure.script)
        defer { fixture.remove() }
        let calls = APICalls()
        await #expect {
            try await fixture.probe {
                await calls.record()
                throw apiError.error
            }.fetch()
        } throws: { failure.matches($0) }
        #expect(await calls.callCount == 2)
    }

    @Test(arguments: UsageFailure.allCases)
    func `whoami login failure prevents API recovery`(failure: UsageFailure) async throws {
        let fixture = try Fixture(usage: failure.script, account: "printf 'Not logged in\\n' >&2; exit 1")
        defer { fixture.remove() }
        let calls = APICalls()
        await #expect {
            try await fixture.probe {
                await calls.record()
                return Self.limits()
            }.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
        #expect(await calls.callCount == 0)
    }

    @Test
    func `usage login failure prevents API recovery even when whoami succeeds`() async throws {
        let fixture = try Fixture(usage: "printf 'Login required\\n' >&2; exit 1")
        defer { fixture.remove() }
        let calls = APICalls()
        await #expect {
            try await fixture.probe {
                await calls.record()
                throw KiroUsageLimitsError.requestFailed("Synthetic expired token")
            }.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
        #expect(await calls.callCount == 1)
    }

    @Test(arguments: UsageFailure.allCases)
    func `API recovery does not trust identity from failed whoami`(failure: UsageFailure) async throws {
        let fixture = try Fixture(
            usage: failure.script,
            account: "printf 'Logged in with Google\\nEmail: untrusted@example.com\\n'; exit 23")
        defer { fixture.remove() }
        let snapshot = try await fixture.probe { Self.limits() }.fetch()
        #expect(snapshot.hasUsageMetrics)
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.authMethod == nil)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.accountEmail(for: .kiro) == nil)
        #expect(usage.loginMethod(for: .kiro) == nil)
    }

    @Test(arguments: UsageFailure.allCases, [false, true])
    func `API recovery preserves cancellation instead of restoring the CLI error`(
        failure: UsageFailure,
        urlCancelled: Bool) async throws
    {
        let fixture = try Fixture(usage: failure.script)
        defer { fixture.remove() }
        let calls = APICalls()
        await #expect(throws: CancellationError.self) {
            try await fixture.probe {
                await calls.record()
                if urlCancelled { throw URLError(.cancelled) }
                throw CancellationError()
            }.fetch()
        }
        #expect(await calls.callCount == 1)
    }

    @Test(arguments: UsageFailure.allCases)
    func `cancelling during API recovery cancels the fetch`(failure: UsageFailure) async throws {
        let fixture = try Fixture(usage: failure.script)
        defer { fixture.remove() }
        let apiStarted = fixture.root.appendingPathComponent("api.started")
        let calls = APICalls()
        let task = Task {
            try await fixture.probe {
                await calls.record()
                try KiroProcessTestSupport.touch(apiStarted)
                try await Task.sleep(for: KiroProcessTestSupport.fixtureSetupTimeout)
                return Self.limits()
            }.fetch()
        }
        defer { task.cancel() }
        do {
            try await KiroProcessTestSupport.waitForFile(apiStarted)
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.callCount == 1)
    }

    @Test
    func `cancelling the usage command never starts API recovery`() async throws {
        let fixture = try Fixture(usage: "exec sleep 30")
        defer { fixture.remove() }
        let calls = APICalls()
        let task = Task {
            try await fixture.probe {
                await calls.record()
                throw KiroUsageLimitsError.requestFailed("Synthetic expired token")
            }.fetch()
        }
        defer { task.cancel() }
        do {
            try await KiroProcessTestSupport.waitForFile(fixture.root.appendingPathComponent("usage.pipe"))
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.callCount == 1)
        #expect(fixture.registry.activePIDs().isEmpty)
    }

    @Test
    func `API retry recovers the exact V3 model reply after CLI token refresh`() async throws {
        let fixture = try Fixture(usage: UsageFailure.v3Prompt.script)
        defer { fixture.remove() }
        let calls = APICalls()
        let snapshot = try await fixture.probe {
            await calls.record()
            if await calls.callCount == 1 {
                throw KiroUsageLimitsError.requestFailed("Synthetic expired token")
            }
            return Self.limits()
        }.fetch()
        #expect(await calls.callCount == 2)
        #expect(snapshot.creditsUsed == 1470.38)
        #expect(snapshot.creditsTotal == 2000)
    }

    @Test
    func `older CLI rejecting V2 retains usage when the API is unavailable`() async throws {
        let fixture = try Fixture(rejectsV2: true)
        defer { fixture.remove() }
        let snapshot = try await fixture.probe {
            throw KiroUsageLimitsError.credentialsUnavailable("Synthetic missing CLI token")
        }.fetch()
        #expect(snapshot.creditsUsed == 20)
        #expect(snapshot.contextUsage?.totalPercentUsed == 7.5)
        for command in ["usage", "context"] {
            let arguments = try fixture.arguments(for: command, transport: "pipe")
            #expect(arguments.contains("--v2"))
            #expect(Array(arguments.suffix(3)) == ["chat", "--no-interactive", "/\(command)"])
        }
    }

    enum UsageFailure: CaseIterable, Sendable {
        case v3Prompt
        case unsupportedV2

        var script: String {
            switch self {
            case .v3Prompt:
                """
                cat <<'KIRO_V3_OUTPUT'
                I can't show usage or quota data. The `/usage` command \
                isn't something I have access to from here, and I can't see your account's usage, \
                token counts, or billing details.
                KIRO_V3_OUTPUT
                exit 0
                """
            case .unsupportedV2:
                "printf 'error: unexpected argument --v2\\n' >&2; exit 2"
            }
        }

        func matches(_ error: Error) -> Bool {
            switch (self, error) {
            case let (.v3Prompt, KiroStatusProbeError.parseError(message)):
                message == "No recognizable usage patterns found. Kiro CLI output format may have changed."
            case let (.unsupportedV2, KiroStatusProbeError.cliFailed(message)):
                message == "error: unexpected argument --v2"
            default:
                false
            }
        }
    }

    enum UnsafeAllowance: CaseIterable, Sendable {
        case zero
        case negative
        case unseparatedBonus

        var limits: KiroUsageLimits {
            switch self {
            case .zero: KiroUsageRecoveryTests.limits(planLimit: 0)
            case .negative: KiroUsageRecoveryTests.limits(planLimit: -1)
            case .unseparatedBonus: KiroUsageRecoveryTests.limits(hasUnseparatedBonus: true)
            }
        }
    }

    enum APIError: CaseIterable, Sendable {
        case missingCredentials
        case requestFailed
        case invalidResponse

        var error: KiroUsageLimitsError {
            switch self {
            case .missingCredentials: .credentialsUnavailable("Synthetic missing CLI token")
            case .requestFailed: .requestFailed("Synthetic HTTP 401")
            case .invalidResponse: .parseError("Synthetic invalid response")
            }
        }
    }

    private actor APICalls {
        private(set) var callCount = 0

        func record() {
            self.callCount += 1
        }
    }

    private static func limits(
        planLimit: Double = 2000,
        planUsed: Double = 1470.38,
        hasUnseparatedBonus: Bool = false) -> KiroUsageLimits
    {
        KiroUsageLimits(
            planLimit: planLimit,
            planUsed: planUsed,
            overageUsed: 0,
            overageCap: nil,
            overageEnabled: false,
            overageCharges: nil,
            overageRate: nil,
            currencyCode: "USD",
            resetsAt: Date(timeIntervalSince1970: 1_793_491_200),
            hasUnseparatedBonus: hasUnseparatedBonus)
    }

    private struct Fixture: Sendable {
        let root: URL
        let cli: URL
        let registry = KiroTestProcessRegistry()

        init(
            usage: String = "printf 'Plan: KIRO FREE | 1 usage breakdowns\\nCredits (20 of 50 covered in plan)\\n'",
            account: String = "printf 'Logged in with Google\\nEmail: kiro@example.com\\n'",
            requiresPTY: Bool = false,
            rejectsV2: Bool = false) throws
        {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-kiro-recovery-\(UUID().uuidString)", isDirectory: true)
            self.cli = self.root.appendingPathComponent("kiro-cli")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            try """
            #!/bin/sh
            transport=pipe
            if [ -t 1 ]; then transport=pty; fi
            if [ "$1" = "whoami" ]; then
              printf '%s\\n' "$@" >> "${0%/*}/whoami.$transport"
              \(account)
              exit 0
            fi
            if [ "$1" != "chat" ]; then exit 1; fi
            case "$3" in
              /usage) command=usage ;;
              /context) command=context ;;
              *) exit 1 ;;
            esac
            printf '%s\\n' "$@" >> "${0%/*}/$command.$transport"
            if [ '\(requiresPTY)' = 'true' ] && [ "$transport" = pipe ]; then exit 23; fi
            if [ '\(rejectsV2)' = 'true' ] && [ "$4" = '--v2' ]; then
              printf "\\033[31merror:\\033[0m unexpected argument '--v2' found\\n" >&2
              exit 2
            fi
            if [ "$command" = usage ]; then
              \(usage)
              exit 0
            fi
            printf 'Context window: 7.5%% used\\n'
            """.write(to: self.cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.cli.path)
        }

        func probe(
            usageLimitsFetcher: @escaping @Sendable () async throws -> KiroUsageLimits) -> KiroStatusProbe
        {
            let cli = self.cli
            return KiroStatusProbe(
                cliBinaryResolver: { cli.path },
                accountProbeTimeout: KiroProcessTestSupport.fixtureAccountTimeout,
                pipeProcessRegistry: self.registry.dependencies,
                usageLimitsFetcher: usageLimitsFetcher)
        }

        func arguments(for command: String, transport: String) throws -> [String] {
            try String(contentsOf: self.root.appendingPathComponent("\(command).\(transport)"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func remove() {
            self.registry.terminateAll()
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
