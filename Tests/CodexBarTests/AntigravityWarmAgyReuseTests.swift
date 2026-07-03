import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityWarmAgyReuseTests {
    // MARK: - Helper-seam tests (tryWarmAgyFetch)

    @Test
    func `warm agy found reuses ports without spawn`() async throws {
        let listeningPortsCallCount = AntigravityWarmLockedCounter()
        let fetchSnapshotCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 9901)] },
                listeningPorts: { pid, _ in
                    listeningPortsCallCount.increment()
                    #expect(pid == 9901)
                    return [56789]
                },
                fetchSnapshot: { ports, _ in
                    fetchSnapshotCallCount.increment()
                    #expect(ports == [56789])
                    return Self.usableSnapshot(email: "warm@example.com")
                }))

        #expect(result?.accountEmail == "warm@example.com")
        #expect(result?.modelQuotas.first?.modelId == "gemini-pro")
        #expect(listeningPortsCallCount.value == 1)
        #expect(fetchSnapshotCallCount.value == 1)
    }

    @Test
    func `no warm agy returns nil`() async throws {
        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [] },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called when no warm agy found")
                    return []
                },
                fetchSnapshot: { _, _ in
                    Issue.record("fetchSnapshot must not be called when no warm agy found")
                    throw AntigravityStatusProbeError.notRunning
                }))

        #expect(result == nil)
    }

    @Test
    func `process infos throws returns nil`() async throws {
        // detectProcessInfos throws (e.g. .missingCSRFToken / .notRunning) — the
        // fast path must swallow it and let the caller fall back to spawning.
        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in throw AntigravityStatusProbeError.missingCSRFToken },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called when discovery throws")
                    return []
                },
                fetchSnapshot: { _, _ in
                    Issue.record("fetchSnapshot must not be called when discovery throws")
                    throw AntigravityStatusProbeError.notRunning
                }))

        #expect(result == nil)
    }

    @Test
    func `warm agy fetch fails returns nil`() async throws {
        let fetchSnapshotCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 7701)] },
                listeningPorts: { _, _ in [55555] },
                fetchSnapshot: { _, _ in
                    fetchSnapshotCallCount.increment()
                    throw AntigravityStatusProbeError.portDetectionFailed("endpoint not ready")
                }))

        // Fetch fails → warm reuse returns nil → caller falls back to spawn
        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 1)
    }

    @Test
    func `ide process ignored not reuseable as warm CLI`() async throws {
        // An IDE language server requires a CSRF token — must NOT be reused via
        // the token-less warm path.
        let ideProcessInfo = AntigravityStatusProbe.ProcessInfoResult(
            pid: 8801,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "abc123",
            commandLine:
            "/Applications/Antigravity IDE.app/Contents/Resources/language_server " +
                "--csrf_token abc123 --app_data_dir antigravity-ide")
        let fetchSnapshotCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [ideProcessInfo] },
                listeningPorts: { _, _ in [44444] },
                fetchSnapshot: { _, _ in
                    fetchSnapshotCallCount.increment()
                    return Self.usableSnapshot(email: "ide@example.com")
                }))

        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 0)
    }

    @Test
    func `owned agy excluded falls back to spawn path`() async throws {
        // CodexBar's own managed `agy` (pid 4242) appears in the process scan.
        // It must NOT be reused through the warm path — doing so would bypass the
        // session lifecycle and let `stopIfIdle` tear it down mid-poll.
        let fetchSnapshotCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 4242)] },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called for a CodexBar-owned agy")
                    return []
                },
                fetchSnapshot: { _, _ in
                    fetchSnapshotCallCount.increment()
                    return Self.usableSnapshot(email: "owned@example.com")
                },
                ownedPID: { 4242 }))

        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 0)
    }

    @Test
    func `external agy reused when owned also present`() async throws {
        // With both an owned `agy` (pid 4242) and an external one (pid 7000), only
        // the external server is reused; the owned pid is filtered out.
        let listeningPortsCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 4242), Self.cliProcessInfo(pid: 7000)] },
                listeningPorts: { pid, _ in
                    listeningPortsCallCount.increment()
                    #expect(pid == 7000)
                    return [50050]
                },
                fetchSnapshot: { _, _ in Self.usableSnapshot(email: "external@example.com") },
                ownedPID: { 4242 }))

        #expect(result?.accountEmail == "external@example.com")
        #expect(listeningPortsCallCount.value == 1)
    }

    @Test
    func `other user agy is ignored`() async throws {
        let listeningPIDs = AntigravityWarmLockedValues<Int>()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 6001), Self.cliProcessInfo(pid: 6002)] },
                listeningPorts: { pid, _ in
                    listeningPIDs.append(pid)
                    return [pid]
                },
                fetchSnapshot: { _, _ in Self.usableSnapshot(email: "same-user@example.com") },
                processOwnerUserID: { pid in pid == 6001 ? 502 : 501 },
                currentUserID: { 501 }))

        #expect(result?.accountEmail == "same-user@example.com")
        #expect(listeningPIDs.value == [6002])
    }

    @Test
    func `account mismatch tries next warm agy`() async throws {
        let listeningPIDs = AntigravityWarmLockedValues<Int>()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            expectedAccountEmail: "selected@example.com",
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 6101), Self.cliProcessInfo(pid: 6102)] },
                listeningPorts: { pid, _ in
                    listeningPIDs.append(pid)
                    return [pid]
                },
                fetchSnapshot: { ports, _ in
                    let email = ports == [6101] ? "other@example.com" : "SELECTED@example.com"
                    return Self.usableSnapshot(email: email)
                }))

        #expect(result?.accountEmail == "SELECTED@example.com")
        #expect(listeningPIDs.value == [6101, 6102])
    }

    @Test
    func `binary mismatch tries next warm agy`() async throws {
        let listeningPIDs = AntigravityWarmLockedValues<Int>()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            expectedBinaryPath: "/selected/agy",
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in
                    [
                        Self.cliProcessInfo(pid: 6151, binaryPath: "/other/agy"),
                        Self.cliProcessInfo(pid: 6152, binaryPath: "/selected/agy"),
                    ]
                },
                listeningPorts: { pid, _ in
                    listeningPIDs.append(pid)
                    return [pid]
                },
                fetchSnapshot: { _, _ in Self.usableSnapshot(email: "selected@example.com") }))

        #expect(result?.accountEmail == "selected@example.com")
        #expect(listeningPIDs.value == [6152])
    }

    @Test
    func `warm probe deadline is shared across discovery and candidates`() async throws {
        let clock = AntigravityWarmTestClock(date: Date(timeIntervalSince1970: 100))
        let listeningPortsCallCount = AntigravityWarmLockedCounter()
        let fetchSnapshotCallCount = AntigravityWarmLockedCounter()

        let result = try await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { timeout in
                    #expect(timeout == 2.0)
                    clock.advance(by: 1.5)
                    return [Self.cliProcessInfo(pid: 6201), Self.cliProcessInfo(pid: 6202)]
                },
                listeningPorts: { _, timeout in
                    listeningPortsCallCount.increment()
                    #expect(timeout == 0.5)
                    clock.advance(by: 0.6)
                    return [62010]
                },
                fetchSnapshot: { _, _ in
                    fetchSnapshotCallCount.increment()
                    return Self.usableSnapshot(email: "late@example.com")
                },
                now: { clock.now() }))

        #expect(result == nil)
        #expect(listeningPortsCallCount.value == 1)
        #expect(fetchSnapshotCallCount.value == 0)
    }

    // MARK: - Integration: fetchUsingWarmSession fast-path branch

    @Test
    func `warm reuse skips spawn path`() async throws {
        let spawnCallCount = AntigravityWarmLockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        let result = try await strategy.fetchUsingWarmSession(
            binary: "/usr/local/bin/agy",
            idleWindow: nil,
            resetAfterFetch: true,
            warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [Self.cliProcessInfo(pid: 1234)] },
                listeningPorts: { _, _ in [40000] },
                fetchSnapshot: { _, _ in Self.usableSnapshot(email: "warm@example.com") }),
            spawnFetch: { _, _, _ in
                spawnCallCount.increment()
                Issue.record("spawn path must not run when a warm agy is reused")
                throw AntigravityStatusProbeError.notRunning
            })

        #expect(result.usage.identity?.accountEmail == "warm@example.com")
        #expect(result.sourceLabel == AntigravityCLIHTTPSFetchStrategy.sourceLabel)
        // The warm path never touches AntigravityCLISession: the spawn seam (the
        // only place beginProbe/finishProbe run) was never invoked.
        #expect(spawnCallCount.value == 0)
    }

    @Test
    func `no warm agy falls back to spawn path`() async throws {
        let spawnCallCount = AntigravityWarmLockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        let result = try await strategy.fetchUsingWarmSession(
            binary: "/usr/local/bin/agy",
            idleWindow: nil,
            resetAfterFetch: true,
            warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in [] },
                listeningPorts: { _, _ in [] },
                fetchSnapshot: { _, _ in throw AntigravityStatusProbeError.notRunning }),
            spawnFetch: { binary, _, resetAfterFetch in
                spawnCallCount.increment()
                #expect(binary == "/usr/local/bin/agy")
                #expect(resetAfterFetch)
                return strategy.makeResult(
                    usage: Self.usableUsage(email: "spawned@example.com"),
                    sourceLabel: AntigravityCLIHTTPSFetchStrategy.sourceLabel)
            })

        #expect(result.usage.identity?.accountEmail == "spawned@example.com")
        #expect(spawnCallCount.value == 1)
    }

    @Test
    func `warm probe cancellation does not fall back to spawn`() async {
        let spawnCallCount = AntigravityWarmLockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        do {
            _ = try await strategy.fetchUsingWarmSession(
                binary: "/usr/local/bin/agy",
                idleWindow: nil,
                resetAfterFetch: true,
                warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                    processInfos: { _ in throw CancellationError() },
                    listeningPorts: { _, _ in [] },
                    fetchSnapshot: { _, _ in throw AntigravityStatusProbeError.notRunning }),
                spawnFetch: { _, _, _ in
                    spawnCallCount.increment()
                    return strategy.makeResult(
                        usage: Self.usableUsage(email: "spawned@example.com"),
                        sourceLabel: AntigravityCLIHTTPSFetchStrategy.sourceLabel)
                })
            Issue.record("cancellation must be rethrown")
        } catch is CancellationError {
            // Expected: cancellation must not be downgraded to a warm miss.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(spawnCallCount.value == 0)
    }

    @Test
    func `long lived session skips external warm scan`() async throws {
        let spawnCallCount = AntigravityWarmLockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        let result = try await strategy.fetchUsingWarmSession(
            binary: "/usr/local/bin/agy",
            idleWindow: 60,
            resetAfterFetch: false,
            warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { _ in
                    Issue.record("long-lived hosts must use their managed session")
                    return [Self.cliProcessInfo(pid: 6301)]
                },
                listeningPorts: { _, _ in [] },
                fetchSnapshot: { _, _ in throw AntigravityStatusProbeError.notRunning }),
            spawnFetch: { _, _, resetAfterFetch in
                spawnCallCount.increment()
                #expect(!resetAfterFetch)
                return strategy.makeResult(
                    usage: Self.usableUsage(email: "managed@example.com"),
                    sourceLabel: AntigravityCLIHTTPSFetchStrategy.sourceLabel)
            })

        #expect(result.usage.identity?.accountEmail == "managed@example.com")
        #expect(spawnCallCount.value == 1)
    }

    // MARK: - Fixtures

    private static func cliProcessInfo(
        pid: Int,
        binaryPath: String = "/usr/local/bin/agy") -> AntigravityStatusProbe.ProcessInfoResult
    {
        AntigravityStatusProbe.ProcessInfoResult(
            pid: pid,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "",
            commandLine: binaryPath)
    }

    private static func usableSnapshot(email: String) -> AntigravityStatusSnapshot {
        AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini Pro",
                    modelId: "gemini-pro",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: email,
            accountPlan: "Pro",
            source: .local)
    }

    private static func usableUsage(email: String) -> UsageSnapshot {
        (try? self.usableSnapshot(email: email).toUsageSnapshot())
            ?? UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .antigravity,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: nil))
    }
}

private final class AntigravityWarmLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        self.lock.withLock {
            self.count += 1
            return self.count
        }
    }

    var value: Int {
        self.lock.withLock { self.count }
    }
}

private final class AntigravityWarmLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        self.lock.withLock {
            self.values.append(value)
        }
    }

    var value: [Value] {
        self.lock.withLock { self.values }
    }
}

private final class AntigravityWarmTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        self.lock.withLock { self.date }
    }

    func advance(by interval: TimeInterval) {
        self.lock.withLock {
            self.date = self.date.addingTimeInterval(interval)
        }
    }
}
