import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct MiMoFirefoxSessionCookieImporterTests {
    @Test
    func `rejects mismatched decoded size`() throws {
        let json = #"{"cookies":[]}"#
        var data = self.mozillaLZ4LiteralFile(json)
        var mismatchedSize = UInt32(json.utf8.count + 1).littleEndian
        withUnsafeBytes(of: &mismatchedSize) { data.replaceSubrange(8..<12, with: $0) }

        do {
            _ = try MiMoFirefoxSessionCookieImporter.decodeSessionRestoreData(data)
            Issue.record("Expected mismatched Firefox session restore size to fail")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .invalidData = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }
    }

    @Test
    func `too small decoded size falls back to valid backup`() throws {
        let (temp, profile, backups) = try self.makeFirefoxProfile()
        defer { try? FileManager.default.removeItem(at: temp) }

        let currentJSON = #"{"cookies":[]}"#
        var current = self.mozillaLZ4LiteralFile(currentJSON)
        var tooSmallSize = UInt32(currentJSON.utf8.count - 1).littleEndian
        withUnsafeBytes(of: &tooSmallSize) { current.replaceSubrange(8..<12, with: $0) }
        try current.write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        let backupJSON = #"{"cookies":[{"host":".xiaomimimo.com","name":"userId","value":"backup-user"}]}"#
        try self.mozillaLZ4LiteralFile(backupJSON)
            .write(to: backups.appendingPathComponent("recovery.baklz4"))

        let outcome = MiMoFirefoxSessionCookieImporter.load(profileDirectory: profile)

        guard case let .loaded(records) = outcome else {
            Issue.record("Expected malformed current state to fall back to the valid backup")
            return
        }
        #expect(records.map(\.value) == ["backup-user"])
    }

    @Test
    func `canonical large payload bypasses raw size prefix trap`() throws {
        let padding = String(repeating: "x", count: 65520)
        let json = #"{"cookies":[],"padding":"\#(padding)"}"#

        let decoded = try MiMoFirefoxSessionCookieImporter.decodeSessionRestoreData(
            self.mozillaLZ4LiteralFile(json))

        #expect(decoded == Data(json.utf8))
    }

    @Test
    func `reads only top level cookies`() throws {
        let data = Data(#"{"nested":{"cookies":[{"host":".xiaomimimo.com","name":"userId","value":"stale"}]}}"#.utf8)

        let records = try MiMoFirefoxSessionCookieImporter.cookieRecords(fromJSONData: data)

        #expect(records.isEmpty)
    }

    @Test
    func `rejects isolated cookie contexts and wrong attribute types`() throws {
        let data = Data(#"""
        {"cookies":[
          {"host":".platform.xiaomimimo.com","name":"api-platform_serviceToken",
           "value":"clean-token","originAttributes":{
             "userContextId":0,"privateBrowsingId":0,
             "firstPartyDomain":"","geckoViewSessionContextId":"","partitionKey":""
           }},
          {"host":".xiaomimimo.com","name":"userId","value":"clean-user","originAttributes":"","isPartitioned":false},
          {"host":".xiaomimimo.com","name":"userId","value":"container-user","originAttributes":{"userContextId":2}},
          {"host":".xiaomimimo.com","name":"userId","value":"private-user","originAttributes":{"privateBrowsingId":1}},
          {"host":".platform.xiaomimimo.com","name":"api-platform_ph","value":"partitioned","isPartitioned":true},
          {"host":".platform.xiaomimimo.com","name":"api-platform_ph","value":"numeric-partition","isPartitioned":0},
          {"host":".platform.xiaomimimo.com","name":"api-platform_ph",
           "value":"boolean-context","originAttributes":{"userContextId":false}},
          {"host":".platform.xiaomimimo.com","name":"api-platform_ph",
           "value":"floating-context","originAttributes":{"privateBrowsingId":0.0}},
          {"host":".platform.xiaomimimo.com","name":"api-platform_ph",
           "value":"unknown-context","originAttributes":{"futureIsolationKey":"value"}}
        ]}
        """#.utf8)

        let records = try MiMoFirefoxSessionCookieImporter.cookieRecords(fromJSONData: data)

        #expect(Set(records.map(\.value)) == Set(["clean-token", "clean-user"]))
    }

    @Test
    func `cookie count is bounded before filtering`() throws {
        let data = Data(#"""
        {"cookies":[
          {"host":"example.com","name":"irrelevant","value":"one"},
          {"host":"example.com","name":"irrelevant","value":"two"}
        ]}
        """#.utf8)

        do {
            _ = try MiMoFirefoxSessionCookieImporter.cookieRecords(fromJSONData: data, maxRecords: 1)
            Issue.record("Expected Firefox session restore cookie count to be bounded")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .resourceLimit = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }
    }

    @Test
    func `mixed cookie array is malformed after applying count bound`() throws {
        let oversized = Data(#"{"cookies":[1,2]}"#.utf8)
        let mixed = Data(#"{"cookies":[{"host":"example.com"},1]}"#.utf8)

        do {
            _ = try MiMoFirefoxSessionCookieImporter.cookieRecords(fromJSONData: oversized, maxRecords: 1)
            Issue.record("Expected mixed Firefox session restore cookie count to be bounded")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .resourceLimit = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }

        do {
            _ = try MiMoFirefoxSessionCookieImporter.cookieRecords(fromJSONData: mixed, maxRecords: 2)
            Issue.record("Expected mixed Firefox session restore cookies to be malformed")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .invalidData = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }
    }

    @Test
    func `input limit stops before older backup`() throws {
        let (temp, profile, backups) = try self.makeFirefoxProfile()
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 0x41, count: 5).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try self.mozillaLZ4LiteralFile(#"{"cookies":[]}"#)
            .write(to: backups.appendingPathComponent("recovery.baklz4"))

        let outcome = MiMoFirefoxSessionCookieImporter.load(
            profileDirectory: profile,
            limits: .init(inputBytes: 4, outputBytes: 1024, cookieRecords: 10))

        guard case .resourceLimited(.inputBytes) = outcome else {
            Issue.record("Expected the current Firefox input limit to stop backup recovery")
            return
        }
    }

    @Test
    func `output limit stops before older backup`() throws {
        let (temp, profile, backups) = try self.makeFirefoxProfile()
        defer { try? FileManager.default.removeItem(at: temp) }

        var oversized = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        var declaredSize = UInt32(129 * 1024 * 1024).littleEndian
        withUnsafeBytes(of: &declaredSize) { oversized.append(contentsOf: $0) }
        try oversized.write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try self.mozillaLZ4LiteralFile(#"{"cookies":[]}"#)
            .write(to: backups.appendingPathComponent("recovery.baklz4"))

        let outcome = MiMoFirefoxSessionCookieImporter.load(profileDirectory: profile)

        guard case .resourceLimited(.outputBytes) = outcome else {
            Issue.record("Expected the current Firefox output limit to stop backup recovery")
            return
        }
    }

    @Test
    func `cookie limit stops before older backup`() throws {
        let (temp, profile, backups) = try self.makeFirefoxProfile()
        defer { try? FileManager.default.removeItem(at: temp) }

        try self.mozillaLZ4LiteralFile(#"{"cookies":[1,2]}"#)
            .write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try self.mozillaLZ4LiteralFile(#"{"cookies":[]}"#)
            .write(to: backups.appendingPathComponent("recovery.baklz4"))

        let outcome = MiMoFirefoxSessionCookieImporter.load(
            profileDirectory: profile,
            limits: .init(inputBytes: 1024, outputBytes: 1024, cookieRecords: 1))

        guard case .resourceLimited(.cookieRecords) = outcome else {
            Issue.record("Expected the current Firefox cookie limit to stop backup recovery")
            return
        }
    }

    @Test
    func `candidates follow deterministic firefox order with newest upgrade only`() {
        let profile = URL(fileURLWithPath: "/tmp/firefox/profile", isDirectory: true)
        let backups = profile.appendingPathComponent("sessionstore-backups", isDirectory: true)
        let upgrades = [
            backups.appendingPathComponent("upgrade.jsonlz4-20250101000000"),
            backups.appendingPathComponent("unrelated.jsonlz4"),
            backups.appendingPathComponent("upgrade.jsonlz4-20260101000000"),
        ]

        let candidates = MiMoFirefoxSessionCookieImporter.orderedSessionRestoreFileCandidates(
            profileDirectory: profile,
            upgradeFiles: upgrades)

        #expect(candidates.map(\.lastPathComponent) == [
            "sessionstore.jsonlz4",
            "recovery.jsonlz4",
            "recovery.baklz4",
            "previous.jsonlz4",
            "upgrade.jsonlz4-20260101000000",
        ])
    }

    private func mozillaLZ4LiteralFile(_ json: String) -> Data {
        var data = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        var decodedSize = UInt32(json.utf8.count).littleEndian
        withUnsafeBytes(of: &decodedSize) { data.append(contentsOf: $0) }
        data.append(self.lz4LiteralBlock(Data(json.utf8)))
        return data
    }

    private func makeFirefoxProfile() throws -> (temp: URL, profile: URL, backups: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-firefox-limit-\(UUID().uuidString)", isDirectory: true)
        let profile = temp.appendingPathComponent("default-release", isDirectory: true)
        let backups = profile.appendingPathComponent("sessionstore-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return (temp, profile, backups)
    }

    private func lz4LiteralBlock(_ payload: Data) -> Data {
        var output = Data()
        let literalCount = payload.count
        if literalCount < 15 {
            output.append(UInt8(literalCount << 4))
        } else {
            output.append(0xF0)
            var remaining = literalCount - 15
            while remaining >= 255 {
                output.append(255)
                remaining -= 255
            }
            output.append(UInt8(remaining))
        }
        output.append(payload)
        return output
    }
}
#endif
