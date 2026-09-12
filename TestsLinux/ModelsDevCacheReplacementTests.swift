import Foundation
import Testing
@testable import CodexBarCore

struct ModelsDevCacheReplacementTests {
    @Test
    func `repeated catalog refreshes remain readable on disk and through the memo`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-dev-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for revision in 1...10 {
            let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(revision))
            try #require(ModelsDevCache.save(
                catalog: ModelsDevCatalog(providers: [:]), fetchedAt: fetchedAt, cacheRoot: root))
            let persisted = try decoder.decode(ModelsDevCacheArtifact.self, from: Data(contentsOf: url))
            #expect(persisted.fetchedAt == fetchedAt)
            #expect(ModelsDevCache.load(cacheRoot: root).artifact == persisted)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == [url.lastPathComponent])
    }
}
