#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

struct ChatGPTBundleTrustCacheTests {
    private static let appPath = "/Applications/ChatGPT.app"
    private static let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"

    @Test
    func `ten scans assess unchanged bundle once and check every running PID`() {
        let cache = ChatGPTBundleTrustCache()
        var assessments = 0
        var checkedPIDs: [Int32] = []
        for pid in Int32(100)..<110 {
            let trusted = ChatGPTCodexProcessTrust.isTrusted(
                pid,
                executablePath: { _ in Self.executable },
                resolvePath: { $0 },
                processIsTrusted: { checkedPIDs.append($0); return true },
                appIsTrusted: { path in
                    cache.isTrusted(path, identity: { _ in Self.identity(1) }, assess: { bundle in
                        #expect(bundle == Self.appPath)
                        return CodexLaunchPreflight.isLaunchCandidateAllowed(
                            path: "/synthetic/ChatGPT.app",
                            fileManager: .default,
                            hasExtendedAttribute: { _, _ in false },
                            spctlAssessment: { assessedPath in
                                #expect(assessedPath == "/synthetic/ChatGPT.app")
                                assessments += 1
                                return .init(
                                    output: "\(assessedPath): accepted\nsource=Notarized Developer ID",
                                    exitStatus: 0)
                            },
                            appSignatureIsTrusted: { _ in true },
                            isMachOExecutable: { _ in false })
                    })
                })
            #expect(trusted)
        }
        #expect(assessments == 1)
        #expect(checkedPIDs == Array(Int32(100)..<110))
        print("ChatGPT trust harness: 10 scans, \(assessments) spctl assessment calls, \(checkedPIDs.count) PID checks")
    }

    @Test
    func `identity changes reassess and failure is retried on the next scan`() {
        let cache = ChatGPTBundleTrustCache()
        var assessments = 0
        var generation = 1
        var allowed = true
        func scan() -> Bool {
            cache.isTrusted(Self.appPath, identity: { _ in Self.identity(generation) }, assess: { _ in
                assessments += 1
                return allowed
            })
        }
        #expect(scan())
        #expect(scan())
        #expect(assessments == 1)
        generation = 2
        allowed = false
        #expect(!scan())
        #expect(!scan())
        #expect(assessments == 3)
        allowed = true
        #expect(scan())
        #expect(scan())
        #expect(assessments == 4)
    }

    @Test
    func `missing identity and replacement during assessment fail closed and clear cached success`() {
        let cache = ChatGPTBundleTrustCache()
        var current: ChatGPTBundleTrustCache.Identity? = Self.identity(1)
        var assessments = 0
        func scan(changesDuringAssessment: Bool = false) -> Bool {
            cache.isTrusted(Self.appPath, identity: { _ in current }, assess: { _ in
                assessments += 1
                if changesDuringAssessment { current = Self.identity(3) }
                return true
            })
        }
        #expect(scan())
        current = nil
        #expect(!scan())
        #expect(assessments == 1)
        current = Self.identity(1)
        #expect(scan())
        #expect(assessments == 2)
        current = Self.identity(2)
        #expect(!scan(changesDuringAssessment: true))
        #expect(scan())
        #expect(assessments == 4)
    }

    @Test(arguments: ["Contents/MacOS/ChatGPT", "Contents/_CodeSignature/CodeResources", "Contents/Info.plist"])
    func `bundle identity detects file modification and replacement`(relativePath: String) throws {
        let root = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(ChatGPTBundleTrustCache.identity(root.path))
        #expect(ChatGPTBundleTrustCache.identity(root.path) == original)
        let file = root.appendingPathComponent(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt.addingTimeInterval(10)],
            ofItemAtPath: file.path)
        #expect(ChatGPTBundleTrustCache.identity(root.path) != original)
        let bytes = try Data(contentsOf: file)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        #expect(ChatGPTBundleTrustCache.identity(root.path) != original)
    }

    @Test
    func `bundle identity rejects missing seal and symlink redirected files`() throws {
        let root = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let seal = root.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.removeItem(at: seal)
        #expect(ChatGPTBundleTrustCache.identity(root.path) == nil)
        try FileManager.default.createSymbolicLink(
            at: seal,
            withDestinationURL: root.appendingPathComponent("Contents/Info.plist"))
        #expect(ChatGPTBundleTrustCache.identity(root.path) == nil)
    }

    @Test(arguments: [false, true])
    func `warm bundle cache cannot bypass process signature or symlink rejection`(redirected: Bool) {
        let cache = ChatGPTBundleTrustCache()
        #expect(cache.isTrusted(Self.appPath, identity: { _ in Self.identity(1) }, assess: { _ in true }))
        #expect(!ChatGPTCodexProcessTrust.isTrusted(
            123,
            executablePath: { _ in Self.executable },
            resolvePath: { redirected ? "/tmp/codex" : $0 },
            processIsTrusted: { _ in redirected },
            appIsTrusted: { _ in
                Issue.record("Rejected processes must not reach even a warm bundle cache")
                return true
            }))
    }

    private static func identity(_ generation: Int) -> ChatGPTBundleTrustCache.Identity {
        [URL(fileURLWithPath: self.appPath): ["generation": generation] as NSDictionary]
    }

    private static func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("chatgpt-trust-\(UUID().uuidString).app")
        for directory in ["Contents/MacOS", "Contents/_CodeSignature"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "ChatGPT", "CFBundleVersion": "1"], format: .xml, options: 0)
        try info.write(to: root.appendingPathComponent("Contents/Info.plist"))
        for file in ["Contents/MacOS/ChatGPT", "Contents/_CodeSignature/CodeResources"] {
            try Data("synthetic".utf8).write(to: root.appendingPathComponent(file))
        }
        return root
    }
}
#endif
