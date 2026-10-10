#if os(macOS) && CODEXBAR_KIMI_DESKTOP_CANDIDATE
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct KimiDesktopNativeCandidateTests {
    @Test(arguments: ["default-temp", "physical-home", "linked-storage"])
    func `native factory reads current session and respects logout`(kind: String) throws {
        var home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-native-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if kind == "physical-home" {
            let path = try #require(realpath(home.path, nil))
            defer { free(path) }
            home = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: directory.appendingPathComponent("CURRENT"))
        let manifest = try #require(Data(base64Encoded: "KAYrrQYAAQIEAwUEAQ=="))
        try manifest.write(to: directory.appendingPathComponent("MANIFEST-000001"))
        let current =
            try #require(
                Data(
                    base64Encoded: "HFa7AZ0AAQEAAAAAAAAAAQAAAAEjX2h0dHBzOi8vd3d3LmtpbWkuY29tAAFhY2Nlc3NfdG9rZW5rAWV5" +
                        "SmhiR2NpT2lKSVV6STFOaUo5LmV5SjBlWEFpT2lKaFkyTmxjM01pTENKaGRXUWlPaUpyYVcxcExtTnZi" +
                        "U0lzSW1WNGNDSTZNVGd3TURBd016WXdNSDAuZml4dHVyZS1zaWduYXR1cmU="))
        let walURL = directory.appendingPathComponent("000004.log")
        try current.write(to: walURL)
        if kind == "linked-storage" {
            let target = home.appendingPathComponent("relocated-synthetic-storage")
            try FileManager.default.moveItem(at: directory, to: target)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        }
        let settings = KimiProviderSettings(cookieSource: .auto, manualCookieHeader: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = KimiDesktopSessionDiscovery.candidate.accessToken(
            settings: settings, homeDirectory: home, now: now)
        let expected =
            "eyJhbGciOiJIUzI1NiJ9.eyJ0eXAiOiJhY2Nlc3MiLCJhdWQiOiJraW1pLmNvbSIsImV4cCI6MTgwMDA" +
            "wMzYwMH0.fixture-signature"
        #expect(session == (kind == "linked-storage" ? nil : expected))
        let deletion =
            try #require(
                Data(base64Encoded: "EvobJDEAAQIAAAAAAAAAAQAAAAAjX2h0dHBzOi8vd3d3LmtpbWkuY29tAAFhY2Nlc3NfdG9rZW4="))
        try (current + deletion).write(to: walURL)
        #expect(KimiDesktopSessionDiscovery.candidate.accessToken(
            settings: settings, homeDirectory: home, now: now) == nil)
    }
}
#endif
