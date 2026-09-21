#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct AugmentKeepaliveLifecycleTests {
    enum Stage {
        case none, transport, unauthorizedTransport, browserDelay, recoveryDelay, persistence, authorization, delivery,
             timer
    }

    @Test(arguments: [
        Stage.transport, .unauthorizedTransport, .browserDelay, .recoveryDelay, .persistence, .authorization, .delivery,
    ])
    func `stop prevents every later keepalive effect`(stage: Stage) async throws {
        let fixture = try Fixture(stage: stage)
        let keepalive = fixture.makeKeepalive()
        let request = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive, requests: [request]) else { return }
        let prior = fixture.effects
        let failures = keepalive._test_consecutiveFailures
        await fixture.stopAndDrain(keepalive, requests: [request])
        #expect(fixture.effects == prior)
        #expect(keepalive._test_consecutiveFailures == failures)
        #expect(fixture.activeNotificationIDs.isEmpty)
    }

    @Test
    func `current notification is submitted and removed when the lifecycle stops`() async throws {
        let fixture = try Fixture(stage: .delivery)
        let keepalive = fixture.makeKeepalive()
        let request = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive, requests: [request]) else { return }
        let notifications = keepalive._test_notificationTasks
        await fixture.gate.open()
        await request.value
        for notification in notifications {
            await notification.value
        }
        #expect(fixture.activeNotificationIDs.count == 1)
        await fixture.stopAndDrain(keepalive)
        #expect(fixture.activeNotificationIDs.isEmpty)
    }

    @Test
    func `stopping a sleeping timer cannot start a browser check`() async throws {
        let fixture = try Fixture(stage: .timer)
        let keepalive = fixture.makeKeepalive()
        keepalive.start()
        #expect(keepalive._test_timerTask != nil)
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive) else { return }
        await fixture.stopAndDrain(keepalive)
        #expect(fixture.effects == Effects())
    }

    @Test
    func `stop retires an automatic refresh already inside transport`() async throws {
        let fixture = try Fixture(stage: .transport)
        let keepalive = fixture.makeKeepalive()
        keepalive.start()
        await fixture.timerGate.open()
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive) else { return }
        let prior = fixture.effects
        await fixture.stopAndDrain(keepalive)
        #expect(fixture.effects == prior)
    }

    @Test
    func `retired refresh cannot publish or clear a restarted refresh`() async throws {
        let fixture = try Fixture(stage: .transport)
        let keepalive = fixture.makeKeepalive()
        let old = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive, requests: [old]) else { return }
        keepalive.stop()
        fixture.holdReplacement = true
        keepalive.start()
        let replacement = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.replacementGate, keepalive: keepalive, requests: [old, replacement]) else {
            return
        }
        let prior = fixture.effects
        await fixture.gate.open()
        await old.value
        #expect(fixture.effects == prior)
        #expect(keepalive._test_isRefreshing)
        await fixture.replacementGate.open()
        await replacement.value
        #expect(!keepalive._test_isRefreshing)
        #expect(fixture.effects.pings == 2)
        #expect(fixture.effects.writes == 1)
        #expect(fixture.effects.cached == 1)
        #expect(fixture.effects.callbacks == 1)
        await fixture.stopAndDrain(keepalive)
    }

    @Test
    func `cancelling one forced caller preserves another active refresh`() async throws {
        let fixture = try Fixture(stage: .transport)
        let keepalive = fixture.makeKeepalive()
        let first = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.gate, keepalive: keepalive, requests: [first]) else { return }
        fixture.holdReplacement = true
        let second = Task { await keepalive.forceRefresh() }
        guard await fixture.waitFor(fixture.replacementGate, keepalive: keepalive, requests: [first, second]) else {
            return
        }
        let prior = fixture.effects
        first.cancel()
        await fixture.gate.open()
        await first.value
        #expect(fixture.effects == prior)
        #expect(keepalive._test_isRefreshing)
        await fixture.replacementGate.open()
        await second.value
        #expect(fixture.effects.writes == 1)
        await keepalive.forceRefresh()
        #expect(fixture.effects.pings == 3)
        #expect(fixture.effects.writes == 2)
        #expect(fixture.effects.callbacks == 2)
        await fixture.stopAndDrain(keepalive)
    }

    @Test
    func `cancelled session store publication preserves memory and disk`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let store = AugmentSessionStore(fileURL: file)
        let fixture = try Fixture(stage: .none)
        await store.setCookies(fixture.session.cookies)
        let previous = try Data(contentsOf: file)
        let write = Task { await store.setCookies([]) }
        write.cancel()
        await write.value
        #expect(await store.getCookies().map(\.value) == ["fixture-session-value"])
        #expect(try Data(contentsOf: file) == previous)
    }

    @Test
    func `current refresh publishes once without logging cookie values`() async throws {
        let fixture = try Fixture(stage: .none)
        let keepalive = fixture.makeKeepalive()
        await keepalive.forceRefresh()
        #expect(fixture.effects == Effects(imports: 2, pings: 1, writes: 1, cached: 1, callbacks: 1))
        #expect(!fixture.logs.joined().contains("fixture-session-value"))
        keepalive.stop()
    }

    private struct Effects: Equatable {
        var imports = 0
        var pings = 0
        var writes = 0
        var cached = 0
        var callbacks = 0
        var opened = 0
        var authorizations = 0
        var delivered = 0
    }

    @MainActor
    private final class Fixture {
        let stage: Stage
        let gate = Gate()
        let replacementGate = Gate()
        let timerGate = Gate()
        let session: AugmentCookieImporter.SessionInfo
        var holdReplacement = false
        var effects = Effects()
        var logs: [String] = []
        var activeNotificationIDs: Set<String> = []

        init(stage: Stage) throws {
            self.stage = stage
            let cookie = try #require(HTTPCookie(properties: [
                .domain: "app.augmentcode.com", .path: "/", .name: "session", .value: "fixture-session-value",
            ]))
            self.session = AugmentCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Synthetic browser")
        }

        func makeKeepalive() -> AugmentSessionKeepalive {
            let dependencies = AugmentKeepaliveDependencies(
                importSession: { _ in
                    self.effects.imports += 1
                    return self.session
                },
                send: { request in
                    self.effects.pings += 1
                    if self.effects.pings == 1, self.stage == .transport || self.stage == .unauthorizedTransport {
                        await self.gate.pause()
                    } else if self.holdReplacement, self.effects.pings == 2 {
                        await self.replacementGate.pause()
                    }
                    let expired = [.unauthorizedTransport, .recoveryDelay, .authorization, .delivery]
                        .contains(self.stage)
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: expired ? 401 : 200,
                        httpVersion: nil,
                        headerFields: ["Set-Cookie": "session=fixture-session-value"])!
                    return (Data("{\"user\":{\"name\":\"Synthetic\"}}".utf8), response)
                },
                sleep: { duration in
                    if duration == .seconds(60) {
                        await (self.stage == .timer ? self.gate : self.timerGate).pause()
                    } else if duration == .seconds(1), self.stage == .browserDelay {
                        await self.gate.pause()
                    } else if duration == .seconds(5), self.stage == .recoveryDelay {
                        await self.gate.pause()
                    }
                },
                storeCookies: { _ in
                    if self.stage == .persistence { await self.gate.pause() }
                    if !Task.isCancelled { self.effects.writes += 1 }
                },
                cacheSession: { _ in self.effects.cached += 1 },
                openDashboard: { self.effects.opened += 1 },
                authorizeNotification: {
                    self.effects.authorizations += 1
                    if self.stage == .authorization { await self.gate.pause() }
                    return true
                },
                deliverNotification: { identifier in
                    self.effects.delivered += 1
                    if self.stage == .delivery { await self.gate.pause() }
                    self.activeNotificationIDs.insert(identifier)
                },
                removeNotification: { self.activeNotificationIDs.remove($0) })
            return AugmentSessionKeepalive(
                dependencies: dependencies,
                logger: { self.logs.append($0) },
                onSessionRecovered: { self.effects.callbacks += 1 })
        }

        func waitFor(
            _ gate: Gate,
            keepalive: AugmentSessionKeepalive,
            requests: [Task<Void, Never>] = []) async -> Bool
        {
            guard await gate.waitUntilEntered() else {
                Issue.record("Keepalive did not reach its controlled suspension")
                await self.stopAndDrain(keepalive, requests: requests)
                return false
            }
            return true
        }

        func stopAndDrain(_ keepalive: AugmentSessionKeepalive, requests: [Task<Void, Never>] = []) async {
            let timer = keepalive._test_timerTask
            let notifications = keepalive._test_notificationTasks
            keepalive.stop()
            await self.gate.open()
            await self.replacementGate.open()
            await self.timerGate.open()
            for request in requests {
                await request.value
            }
            await timer?.value
            for notification in notifications + keepalive._test_notificationTasks {
                await notification.value
            }
            keepalive.stop()
        }
    }

    private actor Gate {
        private var entered = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func pause() async {
            self.entered = true
            if self.isOpen { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }

        func open() {
            self.isOpen = true
            let waiters = self.waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilEntered() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !self.entered, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return self.entered
        }
    }
}
#endif
