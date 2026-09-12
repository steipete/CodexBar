import Foundation

enum KeychainAccessGate {
    static let disableAccessEnvironmentKey = "CODEXBAR_DISABLE_KEYCHAIN_ACCESS"
    static var isDisabled: Bool {
        fatalError("Session paths must not consult Keychain state")
    }
}

@main
struct ProviderSessionFileProof {
    static func main() throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if arguments[1] == "launch" {
            for mode in ["isolated", "production"] {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: arguments[0])
                child.arguments = [mode, root.path]
                child.environment = mode == "isolated" ? [
                    ProviderSessionStoreFile.isolationEnvironmentKey: "1",
                    "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1",
                ] : [:]
                try child.run()
                child.waitUntilExit()
                precondition(child.terminationStatus == 0, "Session-file child proof failed")
            }
            print("Optimized session-file policy: isolated child and fake-root production paths passed")
            return
        }

        let testRoot = root.appendingPathComponent("test")
        let fakeSupport = root.appendingPathComponent("fake-application-support")
        let fakeUserDirectory = fakeSupport.appendingPathComponent("CodexBar")
        try FileManager.default.createDirectory(at: fakeUserDirectory, withIntermediateDirectories: true)
        for filename in ["cursor-session.json", "augment-session.json", "factory-session.json", "notion-session.json"] {
            let sentinel = fakeUserDirectory.appendingPathComponent(filename)
            let original = Data("synthetic-untouched-session".utf8)
            try original.write(to: sentinel)
            var consultedUserPath = false
            let selected = ProviderSessionStoreFile.url(
                for: filename,
                testDirectory: testRoot,
                applicationSupportDirectory: {
                    consultedUserPath = true
                    return fakeSupport
                })
            if arguments[1] == "isolated" {
                precondition(!consultedUserPath)
                precondition(selected == testRoot.appendingPathComponent(filename))
                try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
                try Data("synthetic-test-session".utf8).write(to: selected)
                try FileManager.default.removeItem(at: selected)
                let retained = try Data(contentsOf: sentinel)
                precondition(retained == original)
            } else {
                precondition(consultedUserPath)
                precondition(selected == sentinel)
            }
        }
    }
}
