import Testing
@testable import CodexBarCore

private actor ClaudeCLIAuthStatusProbeCounter {
    private var value = 0

    func increment() {
        self.value += 1
    }

    func count() -> Int {
        self.value
    }
}

struct ClaudeCLIAuthStatusProbeTests {
    @Test
    func `parses logged in status`() {
        #expect(ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":true,"authMethod":"claude.ai"}"#))
    }

    @Test
    func `rejects logged out and malformed status`() {
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":false,"authMethod":"none"}"#))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn("not-json"))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"authMethod":"none"}"#))
    }

    @Test
    func `concurrent identical probes share one subprocess attempt`() async {
        typealias Outcome = ClaudeCLIAuthStatusProbe.Outcome
        let counter = ClaudeCLIAuthStatusProbeCounter()
        let probeOverride: ClaudeCLIAuthStatusProbe.ProbeOverride = { _, _, _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return .timedOut
        }

        let outcomes = await ClaudeCLIAuthStatusProbe.$probeOverrideForTesting.withValue(probeOverride) {
            await withTaskGroup(of: Outcome.self) { group -> [Outcome] in
                for _ in 0..<8 {
                    group.addTask {
                        await ClaudeCLIAuthStatusProbe.probe(
                            binary: "/synthetic/claude",
                            environment: ["HOME": "/synthetic/home"])
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }

        #expect(outcomes.count == 8)
        #expect(outcomes.allSatisfy { $0 == .timedOut })
        #expect(await counter.count() == 1)
    }

    @Test
    func `cancelled waiter reports cancellation without cancelling shared probe`() async {
        let counter = ClaudeCLIAuthStatusProbeCounter()
        let probeOverride: ClaudeCLIAuthStatusProbe.ProbeOverride = { _, _, _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(100))
            return .loggedIn
        }
        let task = Task {
            await ClaudeCLIAuthStatusProbe.$probeOverrideForTesting.withValue(probeOverride) {
                await ClaudeCLIAuthStatusProbe.probe(
                    binary: "/synthetic/cancelled-claude",
                    environment: ["HOME": "/synthetic/cancelled-home"])
            }
        }

        while await counter.count() == 0 {
            await Task.yield()
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }
}
