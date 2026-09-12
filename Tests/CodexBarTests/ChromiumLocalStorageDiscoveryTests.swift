import Foundation
import Testing
@testable import CodexBarCore

struct ChromiumLocalStorageDiscoveryTests {
    @Test
    func `raw storage discovery keeps supported profiles with LevelDB data in stable order`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Profile 2", "Default", "user-work", "Guest Profile", ".hidden"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name).appendingPathComponent("Local Storage/leveldb"),
                withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        let candidates = ChromiumLocalStorageDiscovery.profileCandidates(root: root, labelPrefix: "Browser")
        #expect(candidates.map(\.label) == ["Browser Default", "Browser Profile 2", "Browser user-work"])
        let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
        #expect(candidates.allSatisfy { $0.url.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) })
        #expect(ChromiumLocalStorageDiscovery.profileCandidates(
            root: root.appendingPathComponent("missing"), labelPrefix: "Browser").isEmpty)
    }
}
