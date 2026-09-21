import Foundation
import Testing
@testable import CodexBarCore

struct PiProcessEnvironmentTests {
    @Test
    func `filtering preserves unavailable and known empty process environments`() {
        #expect(PiProcessEnvironment.filtered(nil) == nil)
        #expect(PiProcessEnvironment.filtered([:]) == [:])
        #expect(PiProcessEnvironment.filtered(["PATH": "/synthetic/bin"]) == [:])
        #expect(PiProcessEnvironment.filtered([
            "HOME": "/synthetic/home",
            "OMP_PROFILE": "work",
            "OPENAI_API_KEY": "synthetic-secret",
        ]) == ["HOME": "/synthetic/home", "OMP_PROFILE": "work"])
    }

    @Test
    func `NUL environment parsing retains only Pi selectors and preserves their exact values`() {
        let expected = [
            "HOME": "/synthetic/home",
            "PI_CODING_AGENT_SESSION_DIR": "/synthetic/sessions=work",
            "PI_CODING_AGENT_DIR": "relative agent",
            "PI_CONFIG_DIR": ".custom-omp",
            "OMP_PROFILE": "work",
            "PI_PROFILE": "",
            "XDG_DATA_HOME": "/synthetic/資料",
        ]
        let records = expected.keys.sorted().map { "\($0)=\(expected[$0] ?? "")" } + [
            "OPENAI_API_KEY=synthetic-secret",
            "PATH=/synthetic/bin",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)

        #expect(PiProcessEnvironment.parseNULSeparated(data) == expected)
        #expect(PiProcessEnvironment.parseNULSeparated(Data()) == [:])
        #expect(PiProcessEnvironment.parseNULSeparated(Data([0, 0])) == [:])
        #expect(PiProcessEnvironment.parseNULSeparated(Data("PATH=/synthetic/bin\0".utf8)) == [:])
        #expect(PiProcessEnvironment.parseNULSeparated(Data("OMP_PROFILE=work\0OMP_PROFILE=work\0".utf8)) == [
            "OMP_PROFILE": "work",
        ])
    }

    @Test(arguments: [
        "OMP_PROFILE=work",
        "OMP_PROFILE=work\0partial",
        "OMP_PROFILE\0",
        "OMP_PROFILE=work\0OMP_PROFILE=personal\0",
    ])
    func `incomplete or conflicting environment records remain unavailable`(_ payload: String) {
        #expect(PiProcessEnvironment.parseNULSeparated(Data(payload.utf8)) == nil)
    }

    @Test
    func `invalid UTF8 in a selector remains unavailable without decoding unrelated values`() {
        let invalidSelector = Data("OMP_PROFILE=".utf8) + Data([0xFF, 0])
        #expect(PiProcessEnvironment.parseNULSeparated(invalidSelector) == nil)
        let unrelated = Data("UNRELATED=".utf8) + Data([0xFF, 0])
        #expect(PiProcessEnvironment.parseNULSeparated(unrelated) == [:])
    }

    @Test
    func `Linux environment fixtures distinguish empty missing truncated and oversized reads`() throws {
        let procRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiProcessEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let processRoot = procRoot.appendingPathComponent("101", isDirectory: true)
        try FileManager.default.createDirectory(at: processRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: procRoot) }
        let file = processRoot.appendingPathComponent("environ")

        try Data("OMP_PROFILE=work\0PATH=/synthetic/bin\0".utf8).write(to: file)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 101, procRoot: procRoot) == [
            "OMP_PROFILE": "work",
        ])
        try Data().write(to: file)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 101, procRoot: procRoot) == [:])
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 102, procRoot: procRoot) == nil)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 0, procRoot: procRoot) == nil)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: -1, procRoot: procRoot) == nil)

        try Data("OMP_PROFILE=work".utf8).write(to: file)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 101, procRoot: procRoot) == nil)

        let valueByteCount = PiProcessEnvironment.maxEnvironmentBytes - 6
        let atLimit = Data("HOME=".utf8) + Data(repeating: 120, count: valueByteCount) + Data([0])
        try atLimit.write(to: file)
        let parsed = PiProcessEnvironment.readLinuxEnvironment(pid: 101, procRoot: procRoot)
        #expect(parsed?["HOME"]?.utf8.count == valueByteCount)
        let oversized = atLimit + Data([0])
        try oversized.write(to: file)
        #expect(PiProcessEnvironment.readLinuxEnvironment(pid: 101, procRoot: procRoot) == nil)
        #expect(PiProcessEnvironment.parseNULSeparated(oversized) == nil)
    }

    @Test
    func `scope keys distinguish evidence and selected values while ignoring unrelated environment`() {
        #expect(PiProcessEnvironment.scopeKey(nil) != PiProcessEnvironment.scopeKey([:]))
        #expect(PiProcessEnvironment.scopeKey([:]) == PiProcessEnvironment.scopeKey([
            "PATH": "/synthetic/bin",
            "OPENAI_API_KEY": "synthetic-secret",
        ]))
        let first = ["HOME": "/synthetic/資料", "OMP_PROFILE": "work"]
        let reordered = ["OMP_PROFILE": "work", "HOME": "/synthetic/資料"]
        #expect(PiProcessEnvironment.scopeKey(first) == PiProcessEnvironment.scopeKey(reordered))
        #expect(PiProcessEnvironment.scopeKey(first) != PiProcessEnvironment.scopeKey([
            "HOME": "/synthetic/資料", "OMP_PROFILE": "personal",
        ]))
        #expect(PiProcessEnvironment.scopeKey([:]) != PiProcessEnvironment.scopeKey(["OMP_PROFILE": ""]))
        #expect(PiProcessEnvironment.scopeKey([
            "HOME": "a\u{1F}OMP_PROFILE\u{1F}b", "OMP_PROFILE": "c",
        ]) != PiProcessEnvironment.scopeKey([
            "HOME": "a", "OMP_PROFILE": "b\u{1F}OMP_PROFILE\u{1F}c",
        ]))
    }
}
