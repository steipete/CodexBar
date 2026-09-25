#if DEBUG
import Foundation
import Testing
@testable import CodexBarCore

struct CodexBarConfigStorePermissionsTests {
    @Test(arguments: [false, true])
    func `config secrets are private before publication and cancellation preserves the destination`(
        existingFile: Bool) throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        let original = Data(#"{"providers":[]}"#.utf8)
        let replacement = Data(#"{"providers":[{"id":"claude","cookieHeader":"synthetic-only"}]}"#.utf8)
        if existingFile {
            try original.write(to: url)
        }
        let store = CodexBarConfigStore(fileURL: url)

        let observePublication: @Sendable (URL) throws -> Void = { stagedURL in
            let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try Data(contentsOf: stagedURL) == replacement)
            if existingFile {
                #expect(try Data(contentsOf: url) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
            throw CancellationError()
        }
        CredentialFileWriter.$beforePublishForTesting.withValue(observePublication) {
            #expect(throws: CancellationError.self) {
                try store.saveEncodedData(replacement)
            }
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == (existingFile ? ["config.json"] : []))
        if existingFile {
            #expect(try Data(contentsOf: url) == original)
        }

        try store.saveEncodedData(replacement)
        #expect(try Data(contentsOf: url) == replacement)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((finalAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
#endif
