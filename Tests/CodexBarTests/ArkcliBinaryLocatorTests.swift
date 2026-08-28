import Foundation
import Testing
@testable import CodexBarCore

struct ArkcliBinaryLocatorTests {
    @Test
    func `explicit executable override avoids shell lookup`() {
        let path = "/trusted/bin/arkcli"
        let fileManager = ArkcliFileManager(executables: [path])
        var shellLookupCalled = false
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            shellLookupCalled = true
            return "/untrusted/arkcli"
        }

        let resolved = BinaryLocator.resolveArkcliBinary(
            env: ["ARKCLI_PATH": path],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == path)
        #expect(!shellLookupCalled)
    }

    @Test
    func `path lookup accepts only the arkcli executable name`() {
        let fileManager = ArkcliFileManager(executables: ["/tools/bin/not-arkcli"])
        let resolved = BinaryLocator.resolveArkcliBinary(
            env: ["PATH": "/tools/bin"],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == nil)
    }
}

private final class ArkcliFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
