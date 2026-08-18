import Foundation
import Testing
@testable import CodexBarCore

struct KiroBinaryLocatorTests {
    @Test
    func `resolves kiro CLI from env override`() {
        let overridePath = "/custom/bin/kiro-cli"
        let fileManager = KiroMockFileManager(executables: [overridePath])

        let resolved = BinaryLocator.resolveKiroCLIBinary(
            env: ["KIRO_CLI_PATH": overridePath],
            loginPATH: nil,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == overridePath)
    }

    @Test
    func `resolves kiro CLI from well known home path`() {
        let homePath = "/home/test/.local/bin/kiro-cli"
        let fileManager = KiroMockFileManager(executables: [homePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveKiroCLIBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == homePath)
    }
}

private final class KiroMockFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
