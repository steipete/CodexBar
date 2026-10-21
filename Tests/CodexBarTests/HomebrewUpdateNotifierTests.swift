import Foundation
import Testing
@testable import CodexBar

@MainActor
struct HomebrewUpdateNotifierTests {
    @MainActor
    private final class Fixture {
        struct Request {
            let version: String
            let isCurrent: @MainActor () -> Bool
            let completion: @MainActor (Bool) -> Void
        }

        var submittedVersion: String?
        var requests: [Request] = []
        var removedVersions: [String] = []

        func makeNotifier() -> HomebrewUpdateNotifier {
            HomebrewUpdateNotifier(dependencies: .init(
                lastSubmittedVersion: { self.submittedVersion },
                saveSubmittedVersion: { self.submittedVersion = $0 },
                post: { self.requests.append(Request(version: $0, isCurrent: $1, completion: $2)) },
                remove: { self.removedVersions.append($0) }))
        }
    }

    @Test
    func `a successful notice survives repeated checks and a new notifier instance`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: true)
        notifier.update(availableVersion: "0.74.0", notify: true)
        #expect(fixture.requests.count == 1)
        #expect(fixture.submittedVersion == nil)
        #expect(fixture.requests[0].isCurrent())
        fixture.requests[0].completion(true)

        notifier.update(availableVersion: "0.74.0", notify: true)
        let restarted = fixture.makeNotifier()
        restarted.update(availableVersion: "0.74.0", notify: true)
        #expect(fixture.requests.count == 1)
        #expect(fixture.submittedVersion == "0.74.0")
    }

    @Test
    func `a newer release is announced but a lagging tap is not announced again`() {
        let fixture = Fixture()
        fixture.submittedVersion = "0.74.0"
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.73.0", notify: true)
        #expect(fixture.requests.isEmpty)
        notifier.update(availableVersion: "0.75.0", notify: true)
        #expect(fixture.requests.map(\.version) == ["0.75.0"])
        #expect(fixture.removedVersions.contains("0.74.0"))
    }

    @Test
    func `denied or failed submission can retry on the next check`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: true)
        fixture.requests[0].completion(false)
        #expect(fixture.requests.count == 1)
        #expect(fixture.submittedVersion == nil)
        notifier.update(availableVersion: "0.74.0", notify: true)
        #expect(fixture.requests.count == 2)
        fixture.requests[1].completion(true)
        #expect(fixture.submittedVersion == "0.74.0")
    }

    @Test
    func `manual discovery waits for an automatic check before notifying`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: false)
        #expect(fixture.requests.isEmpty)
        notifier.update(availableVersion: "0.74.0", notify: true)
        #expect(fixture.requests.count == 1)
        fixture.requests[0].completion(false)
        notifier.update(availableVersion: "0.74.0", notify: false)
        #expect(fixture.requests.count == 1)
        notifier.update(availableVersion: "0.74.0", notify: true)
        #expect(fixture.requests.count == 2)
    }

    @Test
    func `starting installation invalidates a notice waiting for authorization`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: true)
        notifier.update(availableVersion: nil, notify: false)
        #expect(!fixture.requests[0].isCurrent())
        fixture.requests[0].completion(true)
        #expect(fixture.submittedVersion == nil)
        #expect(fixture.requests.count == 1)
        #expect(fixture.removedVersions == ["0.74.0"])
    }

    @Test
    func `superseded requests drain before the latest version is submitted`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: true)
        notifier.update(availableVersion: "0.75.0", notify: true)
        #expect(fixture.requests.count == 1)
        #expect(!fixture.requests[0].isCurrent())
        fixture.requests[0].completion(false)
        #expect(fixture.requests.map(\.version) == ["0.74.0", "0.75.0"])
        #expect(fixture.requests[1].isCurrent())
        fixture.requests[1].completion(true)
        #expect(fixture.submittedVersion == "0.75.0")
    }

    @Test
    func `an invalidated notice cannot revive or delete its replacement`() {
        let fixture = Fixture()
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: "0.74.0", notify: true)
        notifier.update(availableVersion: nil, notify: false)
        notifier.update(availableVersion: "0.74.0", notify: true)
        #expect(!fixture.requests[0].isCurrent())
        #expect(fixture.requests.count == 1)
        fixture.requests[0].completion(false)
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests[1].isCurrent())
        fixture.requests[0].completion(true)
        #expect(fixture.submittedVersion == nil)
        #expect(fixture.requests[1].isCurrent())
    }

    @Test
    func `a later successful version check removes a notice from before restart`() {
        let fixture = Fixture()
        fixture.submittedVersion = "0.74.0"
        let notifier = fixture.makeNotifier()
        notifier.update(availableVersion: nil, notify: false)
        #expect(fixture.removedVersions == ["0.74.0"])
        #expect(fixture.requests.isEmpty)
    }
}
