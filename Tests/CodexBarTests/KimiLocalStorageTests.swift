#if os(macOS)
import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct KimiLocalStorageTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE4MDAwMDM2MDB9.signature"

    @Test(arguments: ChromiumLocalStorageDiscovery.defaultBrowsers)
    func `imports regional sessions across the Chromium catalog`(browser: Browser) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(ChromiumProfileLocator.roots(for: [browser], homeDirectories: [home]).first)
        for profile in ["Default", "Profile 2", "user-work", "Guest Profile"] {
            let storage = root.url.appendingPathComponent("\(profile)/Local Storage/leveldb")
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try Self.writeLog(origin: "https://www.kimi.ai", value: Self.token, to: storage)
        }
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#.utf8)
            .write(to: root.url.appendingPathComponent("Local State"))
        let detection = BrowserDetection(homeDirectory: home.path)
        let api = BrowserLocalStorageAPI { origin, browsers, _, logger in
            #expect(browsers == ChromiumLocalStorageDiscovery.defaultBrowsers)
            return BrowserLocalStorageAPI.loadProfiles(
                origin: origin,
                root: root.url,
                browserID: browser.rawValue,
                labelPrefix: root.labelPrefix,
                logger: logger)
        }
        let profiles = api.profiles(
            for: "https://www.kimi.ai",
            browsers: ChromiumLocalStorageDiscovery.defaultBrowsers,
            using: detection,
            logger: { _ in })
        #expect(Set(profiles.map(\.id)) ==
            Set(["Default", "Profile 2", "user-work"].map { "\(browser.rawValue):\($0)" }))
        #expect(profiles.contains { $0.label == "\(root.labelPrefix) — Personal" })
        #expect(KimiCookieImporter.localStorageTokens(
            region: .international, browserDetection: detection, localStorage: api, now: Self.now) == [Self.token])
        #expect(KimiCookieImporter.localStorageTokens(
            region: .china, browserDetection: detection, localStorage: api, now: Self.now).isEmpty)
    }

    @Test
    func `only current access tokens are imported without refresh tokens or duplicates`() {
        let expired = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.signature"
        let api = BrowserLocalStorageAPI { origin, _, _, _ in
            #expect(origin == "https://www.kimi.ai")
            return [.init(id: "fixture", label: "Fixture", entries: [
                .init(key: "refresh_token", value: Self.token),
                .init(key: "access_token", value: expired),
                .init(key: "access_token", value: "not-a-token"),
                .init(key: "access_token", value: "a.b.c"),
                .init(key: "access_token", value: Self.token + "; kimi-auth=x"),
                .init(key: "access_token", value: " \(Self.token)\n"),
                .init(key: "access_token", value: "\"\(Self.token)\""),
            ])]
        }
        #expect(KimiCookieImporter.localStorageTokens(
            region: .international, localStorage: api, now: Self.now) == [Self.token])
        #expect(KimiCookieImporter.localStorageTokens(
            region: .international, localStorage: api, now: Self.now.addingTimeInterval(3600)).isEmpty)
    }

    #if CODEXBAR_KIMI_DESKTOP_CANDIDATE
    /// Sequence/tombstone ordering requires the paired reader; ordinary builds still pin 0.5.5.
    @Test(arguments: ["replacement", "sign-in", "sign-out"], [KimiRegion.china, .international])
    func `imports only the current LevelDB session through the browser adapter`(
        operation: String, region: KimiRegion) throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-current-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Default/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let origin = region.webBaseURL.absoluteString
        try Self.writeLog(
            origin: origin,
            value: operation == "sign-in" ? nil : Self.token + "-old",
            to: storage,
            sequence: 1,
            filename: "000003.log")
        try Self.writeLog(
            origin: origin,
            value: operation == "sign-out" ? nil : Self.token,
            to: storage,
            sequence: 2,
            filename: "000004.log")
        // Deliberately make the older sequence's file newer on disk.
        for (file, time) in [("000003.log", 200.0), ("000004.log", 100.0)] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: time)],
                ofItemAtPath: storage.appendingPathComponent(file).path)
        }
        let api = BrowserLocalStorageAPI { origin, _, _, logger in
            BrowserLocalStorageAPI.loadProfiles(
                origin: origin, root: root, browserID: "fixture", labelPrefix: "Fixture", logger: logger)
        }
        #expect(KimiCookieImporter.localStorageTokens(
            region: region, localStorage: api, now: Self.now) ==
            (operation == "sign-out" ? [] : [Self.token]))
        let otherRegion: KimiRegion = region == .china ? .international : .china
        #expect(KimiCookieImporter.localStorageTokens(
            region: otherRegion, localStorage: api, now: Self.now).isEmpty)
    }

    #endif

    private static func writeLog(
        origin: String,
        value: String?,
        to directory: URL,
        sequence: UInt64 = 0,
        filename: String = "000003.log") throws
    {
        let key = Data("_\(origin)\0access_token".utf8)
        var sequence = sequence.littleEndian
        var batch = withUnsafeBytes(of: &sequence) { Data($0) }
        batch.append(contentsOf: [1, 0, 0, 0])
        batch.append(value == nil ? 0 : 1)
        batch.append(UInt8(key.count))
        batch.append(key)
        if let value {
            let encoded = Data([1]) + Data(value.utf8)
            batch.append(UInt8(encoded.count))
            batch.append(encoded)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in Data([1]) + batch {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0)
            }
        }
        crc = ~crc
        var masked = (((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8).littleEndian
        var record = withUnsafeBytes(of: &masked) { Data($0) }
        let length = UInt16(batch.count).littleEndian
        withUnsafeBytes(of: length) { record.append(contentsOf: $0) }
        record.append(1)
        record.append(batch)
        try record.write(to: directory.appendingPathComponent(filename))
    }
}
#endif
