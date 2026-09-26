import AppKit
import Testing
@testable import CodexBar

struct StatusItemHostingDiagnosticsTests {
    @Test
    func `hosting trace excludes other apps and layers while retaining duplicate candidates`() throws {
        let records = [
            self.window(number: 1),
            self.window(number: 2, owner: "Control Centre"),
            self.window(number: 3, owner: "Other App"),
            self.window(number: 4, layer: 0),
            self.window(number: 5, name: "unrelated private title"),
        ]
        let diagnostic = MenuBarStatusItemWindowProbe.hostingDiagnostics(name: "codexbar-merged", windowInfo: records)
        #expect(diagnostic["layer25Count"] as? Int == 3)
        #expect(diagnostic["layer25Numbers"] as? [Int] == [1, 2, 5])
        let matches = try #require(diagnostic["namedMatches"] as? [[String: Any]])
        #expect(matches.compactMap { $0["number"] as? Int } == [1, 2])
        #expect(matches.first?["bounds"] as? String == "{{20, 0}, {32, 24}}")
        #expect(matches.first?["onscreen"] as? Bool == true)
        let data = try JSONSerialization.data(withJSONObject: diagnostic)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("unrelated private title"))
    }

    @Test
    func `redacted names remain counted without inventing a named match`() {
        var redacted = self.window(number: 1)
        redacted.removeValue(forKey: kCGWindowName as String)
        for name in ["", "codexbar-merged"] {
            let diagnostic = MenuBarStatusItemWindowProbe.hostingDiagnostics(name: name, windowInfo: [redacted])
            #expect(diagnostic["layer25Count"] as? Int == 1)
            #expect(diagnostic["unnamedCount"] as? Int == 1)
            #expect((diagnostic["namedMatches"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    @Test
    func `missing server records alone do not change startup recovery`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true, hasButton: true, hasWindow: true, hasScreen: true, buttonWidth: 32)
        let evidence = StatusItemStartupVisibilityEvidence(
            autosaveName: "codexbar-merged", expectsVisibility: true, visibilityDefault: true, snapshot: snapshot)
        #expect(!MenuBarVisibilityWatcher.hasAnyStartupRecoveryCandidate(
            snapshots: [snapshot], evidence: [evidence], windowSnapshots: [], detectTahoeBlockedStatusItem: true))
    }

    private func window(
        number: Int,
        owner: String = "Control Center",
        layer: Int = 25,
        name: String = "codexbar-merged") -> [String: Any]
    {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowName as String: name,
            kCGWindowBounds as String: ["X": 20, "Y": 0, "Width": 32, "Height": 24],
            kCGWindowIsOnscreen as String: true,
        ]
    }
}
