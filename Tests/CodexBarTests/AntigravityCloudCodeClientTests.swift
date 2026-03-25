import Foundation
import Testing
@testable import CodexBarCore

@Suite("AntigravityCloudCodeClient Tests")
struct AntigravityCloudCodeClientTests {
    @Test("parseModelsResponse extracts models with quota")
    func parseModelsResponse() throws {
        let json = Data(
            """
            {
                "models": {
                    "claude-sonnet-4-5": {
                        "displayName": "Claude Sonnet 4.5",
                        "quotaInfo": {
                            "remainingFraction": 0.75,
                            "resetTime": "2026-03-25T00:00:00Z"
                        }
                    },
                    "gemini-3-pro-high": {
                        "displayName": "Gemini 3 Pro",
                        "quotaInfo": {
                            "remainingFraction": 0.5,
                            "resetTime": "2026-03-25T00:00:00Z"
                        }
                    },
                    "internal-model": {
                        "displayName": "Internal"
                    }
                }
            }
            """.utf8)

        let snapshot = try AntigravityCloudCodeClient.parseModelsResponse(json)

        // Should only include models WITH quotaInfo (skip internal-model)
        #expect(snapshot.modelQuotas.count == 2)

        let claude = snapshot.modelQuotas.first { $0.modelId.contains("claude") }
        #expect(claude != nil)
        #expect(claude?.label == "Claude Sonnet 4.5")
        #expect(claude?.remainingPercent == 75.0)

        let gemini = snapshot.modelQuotas.first { $0.modelId.contains("gemini") }
        #expect(gemini != nil)
        #expect(gemini?.label == "Gemini 3 Pro")
        #expect(gemini?.remainingPercent == 50.0)
    }

    @Test("parseModelsResponse handles empty models")
    func parseEmptyModels() throws {
        let json = Data(
            """
            { "models": {} }
            """.utf8)

        let snapshot = try AntigravityCloudCodeClient.parseModelsResponse(json)
        #expect(snapshot.modelQuotas.isEmpty)
    }

    @Test("parseModelsResponse handles null models field")
    func parseNullModels() throws {
        let json = Data(
            """
            {}
            """.utf8)

        let snapshot = try AntigravityCloudCodeClient.parseModelsResponse(json)
        #expect(snapshot.modelQuotas.isEmpty)
    }

    @Test("parseProjectId extracts string project ID")
    func parseProjectIdString() {
        let json = Data(
            """
            {
                "cloudaicompanionProject": "my-project-123",
                "codeAssistEnabled": true
            }
            """.utf8)

        let projectId = AntigravityCloudCodeClient.parseProjectId(from: json)
        #expect(projectId == "my-project-123")
    }

    @Test("parseProjectId extracts object project ID")
    func parseProjectIdObject() {
        let json = Data(
            """
            {
                "cloudaicompanionProject": { "id": "my-project-456" }
            }
            """.utf8)

        let projectId = AntigravityCloudCodeClient.parseProjectId(from: json)
        #expect(projectId == "my-project-456")
    }

    @Test("parseProjectId extracts nested projectId fallback")
    func parseProjectIdNestedProjectId() {
        let json = Data(
            """
            {
                "cloudaicompanionProject": { "projectId": "my-project-789" }
            }
            """.utf8)

        let projectId = AntigravityCloudCodeClient.parseProjectId(from: json)
        #expect(projectId == "my-project-789")
    }

    @Test("parseProjectId returns nil for missing field")
    func parseProjectIdMissing() {
        let json = Data(
            """
            { "codeAssistEnabled": true }
            """.utf8)

        let projectId = AntigravityCloudCodeClient.parseProjectId(from: json)
        #expect(projectId == nil)
    }

    @Test("parseProjectId returns nil for empty string")
    func parseProjectIdEmptyString() {
        let json = Data(
            """
            { "cloudaicompanionProject": "" }
            """.utf8)

        let projectId = AntigravityCloudCodeClient.parseProjectId(from: json)
        #expect(projectId == nil)
    }

    @Test("parseModelsResponse parses reset time correctly")
    func parseResetTime() throws {
        let json = Data(
            """
            {
                "models": {
                    "test-model": {
                        "displayName": "Test",
                        "quotaInfo": {
                            "remainingFraction": 0.3,
                            "resetTime": "2026-03-25T12:00:00Z"
                        }
                    }
                }
            }
            """.utf8)

        let snapshot = try AntigravityCloudCodeClient.parseModelsResponse(json)
        let model = try #require(snapshot.modelQuotas.first)
        #expect(model.resetTime != nil)
    }
}
