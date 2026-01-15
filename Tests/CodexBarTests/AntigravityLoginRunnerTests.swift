import CodexBarCore
import Testing

@Test("AntigravityLoginRunner Result types")
func antigravityLoginRunnerResultTypes() {
    let successResult: AntigravityLoginRunner.Result = .success(
        email: "test@example.com",
        refreshToken: "token123",
        projectId: "project-456")

    switch successResult {
    case let .success(email, refreshToken, projectId):
        #expect(email == "test@example.com")
        #expect(refreshToken == "token123")
        #expect(projectId == "project-456")
    default:
        Issue.record("Expected success result")
    }

    let cancelledResult: AntigravityLoginRunner.Result = .cancelled
    switch cancelledResult {
    case .cancelled:
        break
    default:
        Issue.record("Expected cancelled result")
    }

    let failedResult: AntigravityLoginRunner.Result = .failed("Test error message")
    switch failedResult {
    case let .failed(message):
        #expect(message == "Test error message")
    default:
        Issue.record("Expected failed result")
    }
}
