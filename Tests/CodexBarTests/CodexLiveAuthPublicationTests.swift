#if DEBUG
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct CodexLiveAuthPublicationTests {
    @Test(arguments: [false, true])
    func `live auth is private before publication and cancellation preserves the destination`(
        existingFile: Bool) throws
    {
        let directory = CodexCredentialFixtures.root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auth.json")
        let original = Data("original-synthetic-auth".utf8)
        let replacement = Data("replacement-synthetic-auth".utf8)
        if existingFile {
            try original.write(to: url)
        }

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
                try DefaultCodexLiveAuthSwapper().swapLiveAuthData(replacement, liveHomeURL: directory)
            }
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == (existingFile ? ["auth.json"] : []))
        if existingFile {
            #expect(try Data(contentsOf: url) == original)
        }

        try DefaultCodexLiveAuthSwapper().swapLiveAuthData(replacement, liveHomeURL: directory)
        #expect(try Data(contentsOf: url) == replacement)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((finalAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
#endif
