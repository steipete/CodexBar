import CodexBarCore
import Foundation
import Testing

@Suite
struct ProviderTokenResolverTests {
    @Test
    func zaiResolutionUsesEnvironmentToken() {
        let env = [ZaiSettingsReader.apiTokenKey: "token"]
        let resolution = ProviderTokenResolver.zaiResolution(environment: env)
        #expect(resolution?.token == "token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func copilotResolutionTrimsToken() {
        let env = ["COPILOT_API_TOKEN": "  token  "]
        let resolution = ProviderTokenResolver.copilotResolution(environment: env)
        #expect(resolution?.token == "token")
    }

    @Test
    func warpResolutionUsesEnvironmentToken() {
        let env = ["WARP_API_KEY": "wk-test-token"]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution?.token == "wk-test-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func warpResolutionTrimsToken() {
        let env = ["WARP_API_KEY": "  wk-token  "]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution?.token == "wk-token")
    }

    @Test
    func warpResolutionReturnsNilWhenMissing() {
        let env: [String: String] = [:]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution == nil)
    }

    @Test
    func kiloResolutionPrefersEnvironmentOverAuthFile() throws {
        let fileURL = try self.makeKiloAuthFile(contents: #"{"kilo":{"access":"file-token"}}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let env = [KiloSettingsReader.apiTokenKey: "env-token"]
        let resolution = ProviderTokenResolver.kiloResolution(environment: env, authFileURL: fileURL)

        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func kiloResolutionFallsBackToAuthFile() throws {
        let fileURL = try self.makeKiloAuthFile(contents: #"{"kilo":{"access":"file-token"}}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.kiloResolution(environment: [:], authFileURL: fileURL)

        #expect(resolution?.token == "file-token")
        #expect(resolution?.source == .authFile)
    }

    @Test
    func kiloResolutionReturnsNilForMalformedAuthFile() throws {
        let fileURL = try self.makeKiloAuthFile(contents: #"{not-json}"#)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let resolution = ProviderTokenResolver.kiloResolution(environment: [:], authFileURL: fileURL)
        #expect(resolution == nil)
    }

    private func makeKiloAuthFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("auth.json", isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
