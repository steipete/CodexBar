import AppKit
import Foundation
import Testing
import XCTest
@testable import CodexBar
@testable import CodexBarCore

struct OpenRouterSharingTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `activity namespaces reach sharing only as public families with original provider totals`(
        engine: ProviderPluginEngineKind) async throws
    {
        let dashboard = try await OpenRouterSharingFixture.dashboard(engine: engine)
        let group = try #require(dashboard.groups.first)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.totalTokens == 900)
        #expect(group.tokenMix.reasoningTokens == 140)
        #expect(group.totalCost == 0.9375)
        #expect(Set(group.models.map(\.modelName)) == [
            "openai/gpt-4o", "acme-namespace/gpt-private-fixture",
            "anthropic/claude-sonnet-4", "private-vendor/unknown-fixture",
        ])

        let payload = try #require(ShareStatsBuilder.make(model: dashboard))
        #expect(payload.totalTokens == 900)
        #expect(!payload.hasPartialTokens)
        #expect(payload.providers.count == 1)
        #expect(payload.providers.first?.provider == .openrouter)
        #expect(payload.providers.first?.totalTokens == 900)
        #expect(payload.providers.first?.estimatedCost == 0.9375)
        #expect(payload.currencies.first?.currencyCode == "USD")
        #expect(payload.currencies.first?.estimatedCost == 0.9375)
        #expect(payload.topModels == [
            ShareStatsModelPayload(
                provider: .openrouter,
                providerName: "OpenRouter",
                modelName: "GPT",
                currencyCode: "USD",
                totalTokens: 700,
                estimatedCost: 0.75),
            ShareStatsModelPayload(
                provider: .openrouter,
                providerName: "OpenRouter",
                modelName: "Claude",
                currencyCode: "USD",
                totalTokens: 150,
                estimatedCost: 0.125),
        ])
        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains("GPT"))
        #expect(text.contains("Claude"))
        #expect(text.contains("OpenRouter"))
        for raw in group.models.map(\.modelName) + ["acme-namespace", "private-vendor", "endpoint-"] {
            #expect(!text.contains(raw))
        }
    }
}

@MainActor
final class OpenRouterSharingNativeProofTests: XCTestCase {
    func test_activityModelFamiliesReachSharedImageAndText() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_OPENROUTER_SHARING_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENROUTER_SHARING_PROOF_DIR for synthetic sharing proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = output.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              home.count > parent.count, home.starts(with: parent),
              let expected = environment["CODEXBAR_OPENROUTER_SHARING_EXPECT_MODELS"],
              ["0", "2"].contains(expected)
        else { return XCTFail("Use a contained home, credential isolation, and explicit expected model count") }
        guard NSApplication.shared.delegate == nil else { return XCTFail("Use a standalone test host") }
        let dashboard = try await OpenRouterSharingFixture.dashboard(engine: .quickJS)
        let payload = try XCTUnwrap(ShareStatsBuilder.make(model: dashboard))
        XCTAssertEqual(payload.totalTokens, 900)
        XCTAssertEqual(payload.providers.first?.provider, .openrouter)
        XCTAssertEqual(payload.providers.first?.estimatedCost, 0.9375)
        XCTAssertEqual(payload.topModels.count, Int(expected))
        if expected == "2" {
            XCTAssertEqual(payload.topModels.map(\.modelName), ["GPT", "Claude"])
            XCTAssertEqual(payload.topModels.map(\.totalTokens), [700, 150])
        }
        let text = ShareStatsFormatting.text(payload)
        for raw in ["openai/", "anthropic/", "acme-namespace", "private-vendor", "endpoint-"] {
            XCTAssertFalse(text.contains(raw))
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try text.write(to: output.appendingPathComponent("share.txt"), atomically: true, encoding: .utf8)
        let png = try XCTUnwrap(ShareStatsRenderer.pngData(for: payload))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 1200)
        XCTAssertEqual(image.pixelsHigh, 630)
        try png.write(to: output.appendingPathComponent("share.png"))
        try JSONSerialization.data(withJSONObject: [
            "syntheticOnly": true,
            "totalTokens": XCTUnwrap(payload.totalTokens),
            "topModels": payload.topModels.map {
                [
                    "family": $0.modelName,
                    "provider": $0.provider.rawValue,
                    "tokens": $0.totalTokens.map { $0 as Any } ?? NSNull(),
                ]
            },
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("state.json"))
    }
}

private enum OpenRouterSharingFixture {
    static func dashboard(engine: ProviderPluginEngineKind) async throws -> SpendDashboardModel {
        let snapshot = try await OpenRouterReasoningTestSupport.snapshot(engine: engine, activityBody: #"""
        {"data":[
          {"date":"2026-08-17","model_permaslug":"openai/gpt-4o","endpoint_id":"endpoint-a",
           "prompt_tokens":400,"completion_tokens":100,"reasoning_tokens":120,"requests":1,"usage":0.5},
          {"date":"2026-08-17","model_permaslug":"acme-namespace/gpt-private-fixture","endpoint_id":"endpoint-b",
           "prompt_tokens":200,"completion_tokens":0,"reasoning_tokens":20,"requests":1,"usage":0.25},
          {"date":"2026-08-16","model_permaslug":"anthropic/claude-sonnet-4","endpoint_id":"endpoint-c",
           "prompt_tokens":100,"completion_tokens":50,"reasoning_tokens":0,"requests":1,"usage":0.125},
          {"date":"2026-08-16","model_permaslug":"private-vendor/unknown-fixture","endpoint_id":"endpoint-d",
           "prompt_tokens":30,"completion_tokens":20,"requests":1,"usage":0.0625}
        ]}
        """#)
        let cost = try #require(snapshot.costUsage)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SpendDashboardModel.build(
            inputs: [.init(provider: .openrouter, displayName: "OpenRouter", snapshot: cost)],
            requestedDays: 30,
            now: OpenRouterReasoningTestSupport.now,
            calendar: calendar)
    }
}
