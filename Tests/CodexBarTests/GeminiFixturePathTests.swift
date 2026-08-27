import Foundation
import Testing

struct GeminiFixturePathTests {
    @Test
    func `fnm fixture PATH preserves inherited peer lookup and fixture priority`() throws {
        let fixture = try GeminiTestEnvironment()
        defer { fixture.cleanup() }
        let inheritedBin = fixture.homeURL.appendingPathComponent("peer-bin")
        try FileManager.default.createDirectory(at: inheritedBin, withIntermediateDirectories: true)
        try FakeExecutable.install(
            "printf '%s\\n' 'inherited-peer'\n",
            at: inheritedBin.appendingPathComponent("codexbar-path-peer"))
        try FakeExecutable.install("exit 23\n", at: inheritedBin.appendingPathComponent("fnm"))
        let geminiBinary = try fixture.writeFakeGeminiCLI(layout: .fnmBundle)
        _ = try fixture.writeFakeFnm(
            geminiPackageJSONPath: fixture.homeURL.appendingPathComponent("package.json").path)

        let path = fixture.fnmFixturePath(geminiBinary: geminiBinary, inheritedPath: inheritedBin.path)
        let environment = [
            "PATH": path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
        ]
        // Model a peer's /usr/bin/env lookup while the same fixture PATH override is active.
        for (arguments, expected) in [
            (["codexbar-path-peer"], "inherited-peer"),
            (["fnm", "current"], "v24.6.0"),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = try #require(String(
                bytes: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8))
            try #require(process.terminationStatus == 0, "\(text)")
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        }
        #expect(path.components(separatedBy: ":") == [
            fixture.homeURL.appendingPathComponent("bin").path,
            geminiBinary.deletingLastPathComponent().path,
            inheritedBin.path,
        ])
    }

    @Test(arguments: [nil, ""] as [String?])
    func `fnm fixture PATH handles missing or empty inherited PATH`(inheritedPath: String?) throws {
        let fixture = try GeminiTestEnvironment()
        defer { fixture.cleanup() }
        let geminiBinary = try fixture.writeFakeGeminiCLI(layout: .fnmBundle)

        let path = fixture.fnmFixturePath(geminiBinary: geminiBinary, inheritedPath: inheritedPath)

        #expect(path.components(separatedBy: ":") == [
            fixture.homeURL.appendingPathComponent("bin").path,
            geminiBinary.deletingLastPathComponent().path,
        ])
    }
}
