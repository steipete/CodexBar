#if DEBUG
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct LifetimeSpendRuntimeProofTests {
    @Test
    func `proof mode is inert without its explicit root`() {
        #expect(LifetimeSpendRuntimeProofConfiguration.resolve(environment: [:]) == .notRequested)
    }

    @Test
    func `proof mode refuses roots outside private tmp`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-the-approved-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = LifetimeSpendRuntimeProofConfiguration.resolve(environment: [
            LifetimeSpendRuntimeProofConfiguration.rootEnvironmentKey: root.path,
            LifetimeSpendRuntimeProofConfiguration.phaseEnvironmentKey: "record",
        ])
        #expect(resolution == .rejected)
    }

    @Test
    func `proof mode accepts only a private sentinel directory`() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexbar-lifetime-proof.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path)
        let runID = UUID().uuidString
        let sentinel = Data("{\"schemaVersion\":1,\"runID\":\"\(runID)\"}".utf8)
        try sentinel.write(
            to: root.appendingPathComponent(LifetimeSpendRuntimeProofConfiguration.sentinelFilename),
            options: .atomic)

        let resolution = LifetimeSpendRuntimeProofConfiguration.resolve(environment: [
            LifetimeSpendRuntimeProofConfiguration.rootEnvironmentKey: root.path,
            LifetimeSpendRuntimeProofConfiguration.phaseEnvironmentKey: "reload",
        ])
        #expect(resolution == .accepted(.init(root: root.standardizedFileURL, phase: .reload, runID: runID)))
    }

    @Test
    func `proof mode refuses a symlink into its approved prefix`() throws {
        let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexbar-lifetime-proof.\(UUID().uuidString)", isDirectory: true)
        let link = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexbar-lifetime-proof.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: destination.path)
        let sentinel = Data("{\"schemaVersion\":1,\"runID\":\"\(UUID().uuidString)\"}".utf8)
        try sentinel.write(
            to: destination.appendingPathComponent(LifetimeSpendRuntimeProofConfiguration.sentinelFilename),
            options: .atomic)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let resolution = LifetimeSpendRuntimeProofConfiguration.resolve(environment: [
            LifetimeSpendRuntimeProofConfiguration.rootEnvironmentKey: link.path,
            LifetimeSpendRuntimeProofConfiguration.phaseEnvironmentKey: "record",
        ])
        #expect(resolution == .rejected)
    }

    @Test
    func `proof mode refuses a symlink sentinel`() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexbar-lifetime-proof.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path)
        let target = root.appendingPathComponent("sentinel-target.json")
        let sentinel = Data("{\"schemaVersion\":1,\"runID\":\"\(UUID().uuidString)\"}".utf8)
        try sentinel.write(to: target, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(LifetimeSpendRuntimeProofConfiguration.sentinelFilename),
            withDestinationURL: target)

        let resolution = LifetimeSpendRuntimeProofConfiguration.resolve(environment: [
            LifetimeSpendRuntimeProofConfiguration.rootEnvironmentKey: root.path,
            LifetimeSpendRuntimeProofConfiguration.phaseEnvironmentKey: "record",
        ])
        #expect(resolution == .rejected)
    }

    @Test
    func `proof mode accepts only owner read write ledger permissions`() throws {
        let ledgerURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexbar-lifetime-proof-ledger.\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: ledgerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: ledgerURL.path)
        #expect(LifetimeSpendRuntimeProofConfiguration.verifiedLedgerPermissions(at: ledgerURL) == "0600")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: ledgerURL.path)
        #expect(LifetimeSpendRuntimeProofConfiguration.verifiedLedgerPermissions(at: ledgerURL) == nil)
    }
}
#endif
