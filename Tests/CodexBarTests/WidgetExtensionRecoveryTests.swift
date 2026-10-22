import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct WidgetExtensionRecoveryTests {
    private let installedAt = Date(timeIntervalSince1970: 200)
    private let path = "/synthetic/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget"

    @Test
    func `unchanged version performs no work`() {
        let defaults = InMemoryUserDefaults(values: [WidgetExtensionRecovery.versionKey: "101"])
        let count = WidgetExtensionRecovery.recover(
            version: "101",
            defaults: defaults,
            processes: { Issue.record("enumerated processes"); return [] },
            installedAt: { Issue.record("read installation"); return nil },
            owns: { _ in Issue.record("checked ownership"); return true },
            exists: { _ in Issue.record("read executable"); return true },
            terminate: { _ in Issue.record("sent signal"); return true },
            reload: { Issue.record("reloaded timelines") })
        #expect(count == nil)
    }

    @Test
    func `updated launch terminates only owned stale processes once before reloading`() {
        let defaults = InMemoryUserDefaults(values: [WidgetExtensionRecovery.versionKey: "100"])
        let old = self.process(1, startedAt: 100)
        let current = self.process(2, startedAt: 201)
        let foreign = self.process(3, startedAt: 100)
        let deleted = self.process(4, startedAt: 201, path: "/deleted/CodexBarWidget")
        let simultaneous = self.process(5, startedAt: 200)
        var events: [String] = []
        func recover() -> Int? {
            WidgetExtensionRecovery.recover(
                version: "101",
                defaults: defaults,
                processes: { [old, current, foreign, deleted, simultaneous] },
                installedAt: { self.installedAt },
                owns: { $0.pid != foreign.pid },
                exists: { $0 != deleted.executablePath },
                terminate: { events.append("term:\($0.pid)"); return true },
                reload: { events.append("reload") })
        }
        #expect(recover() == 2)
        #expect(events == ["term:1", "term:4", "reload"])
        #expect(defaults.string(forKey: WidgetExtensionRecovery.versionKey) == "101")
        #expect(recover() == nil)
        #expect(events == ["term:1", "term:4", "reload"])
    }

    @Test
    func `unknown installation time never proves an existing process stale`() {
        var signaled = false
        var reloaded = false
        let count = WidgetExtensionRecovery.recover(
            version: "101",
            defaults: InMemoryUserDefaults(),
            processes: { [self.process(1, startedAt: 100)] },
            installedAt: { nil },
            owns: { _ in true },
            exists: { _ in true },
            terminate: { _ in signaled = true; return true },
            reload: { reloaded = true })
        #expect(count == 0)
        #expect(!signaled)
        #expect(reloaded)
    }

    private func process(_ pid: Int32, startedAt: TimeInterval, path: String? = nil)
        -> WidgetExtensionRecovery.Process
    {
        .init(pid: pid, startedAt: Date(timeIntervalSince1970: startedAt), executablePath: path ?? self.path)
    }
}
