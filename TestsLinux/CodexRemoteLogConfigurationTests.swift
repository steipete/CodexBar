import Foundation
import Testing
@testable import CodexBarCore

struct CodexRemoteLogConfigurationTests {
    private struct Fixture: Sendable {
        let root: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try CodexRemoteLogStorage.privateDirectory(self.root)
        }

        func clean() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    @Test func `content revisions detect same length same inode changes after restoring modification time`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ssh = fixture.root.appendingPathComponent(".ssh")
        try CodexRemoteLogStorage.privateDirectory(ssh)
        let config = ssh.appendingPathComponent("config")
        let included = ssh.appendingPathComponent("route.conf")
        let primaryA = Data("Include route.conf\nHost fixture\n HostName first\n".utf8)
        let primaryB = Data("Include route.conf\nHost fixture\n HostName other\n".utf8)
        let includedA = Data("Host fixture\n Port 2200\n".utf8)
        let includedB = Data("Host fixture\n Port 2201\n".utf8)
        try primaryA.write(to: config)
        try includedA.write(to: included)
        // Whole-second timestamps round-trip exactly through Foundation on Darwin and Linux.
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        for file in [config, included] {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        }
        let environment = ["HOME": fixture.root.path]
        let before = CodexRemoteLogMirror.configurationFingerprint(environment: environment)
        #expect(before != CodexRemoteLogMirror.unavailableConfigurationFingerprint)
        try Self.overwritePreservingMetadata(config, data: primaryB)
        let changedPrimary = CodexRemoteLogMirror.configurationFingerprint(environment: environment)
        #expect(changedPrimary != before)
        try Self.overwritePreservingMetadata(included, data: includedB)
        #expect(CodexRemoteLogMirror.configurationFingerprint(environment: environment) != changedPrimary)
    }

    @Test func `configuration fingerprint never follows IdentityFile and rejects unreadable inputs`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let config = fixture.root.appendingPathComponent(".ssh/config")
        var reads: [URL] = []
        let environment = ["HOME": fixture.root.path]
        let revision = CodexRemoteLogMirror.configurationFingerprint(environment: environment) { url in
            reads.append(url)
            if url == config { return Data("Host fixture\n IdentityFile /synthetic/never-read-key\n".utf8) }
            return nil
        }
        #expect(revision != CodexRemoteLogMirror.unavailableConfigurationFingerprint)
        #expect(reads.count == 2)
        #expect(!reads.contains { $0.path.contains("never-read-key") })
        let unavailable = CodexRemoteLogMirror.configurationFingerprint(environment: environment) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(unavailable == CodexRemoteLogMirror.unavailableConfigurationFingerprint)
    }

    @Test func `invalid oversized and private key includes cannot produce a usable configuration revision`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ssh = fixture.root.appendingPathComponent(".ssh")
        try CodexRemoteLogStorage.privateDirectory(ssh)
        let config = ssh.appendingPathComponent("config")
        let included = ssh.appendingPathComponent("route.conf")
        try Data("Include route.conf\n".utf8).write(to: config)
        let environment = ["HOME": fixture.root.path]
        for invalid in [
            Data([0xFF, 0xFE]),
            Data(repeating: 65, count: 1024 * 1024 + 1),
            Data("-----BEGIN OPENSSH PRIVATE KEY-----\nSYNTHETIC_NOT_A_KEY\n".utf8),
        ] {
            try invalid.write(to: included)
            #expect(CodexRemoteLogMirror.configurationFingerprint(environment: environment) ==
                CodexRemoteLogMirror.unavailableConfigurationFingerprint)
        }
    }

    @Test(arguments: ["../route.conf", "[ab].conf", "nested/*/route.conf", "~other/config", "%d/config", "$CONFIG"])
    func `unsupported direct includes cannot silently preserve a usable revision`(include: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let config = fixture.root.appendingPathComponent(".ssh/config")
        let revision = CodexRemoteLogMirror.configurationFingerprint(environment: ["HOME": fixture.root.path]) { url in
            url == config ? Data("Include \(include)\n".utf8) : nil
        }
        #expect(revision == CodexRemoteLogMirror.unavailableConfigurationFingerprint)
    }

    @Test(arguments: [false, true])
    func `config symlink target content changes invalidate the revision`(primary: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ssh = fixture.root.appendingPathComponent(".ssh")
        try CodexRemoteLogStorage.privateDirectory(ssh)
        let config = ssh.appendingPathComponent("config")
        let target = fixture.root.appendingPathComponent("route-target")
        try Data("Host fixture\n HostName first\n".utf8).write(to: target)
        if !primary { try Data("Include route.conf\n".utf8).write(to: config) }
        try FileManager.default.createSymbolicLink(
            at: primary ? config : ssh.appendingPathComponent("route.conf"), withDestinationURL: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
        let environment = ["HOME": fixture.root.path]
        let before = CodexRemoteLogMirror.configurationFingerprint(environment: environment)
        #expect(before != CodexRemoteLogMirror.unavailableConfigurationFingerprint)
        try Self.overwritePreservingMetadata(target, data: Data("Host fixture\n HostName other\n".utf8))
        #expect(CodexRemoteLogMirror.configurationFingerprint(environment: environment) != before)
    }

    private static func overwritePreservingMetadata(_ file: URL, data: Data) throws {
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let date = try #require(before[.modificationDate] as? Date)
        #expect((before[.size] as? NSNumber)?.intValue == data.count)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.size] as? NSNumber == after[.size] as? NSNumber)
    }
}
