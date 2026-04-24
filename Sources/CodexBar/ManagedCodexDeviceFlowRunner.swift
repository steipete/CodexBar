import CodexBarCore
import Foundation

/// Thin indirection around `CodexDeviceFlow` so `ManagedCodexAccountService`
/// can be driven by fakes in tests, mirroring the existing
/// `ManagedCodexLoginRunning` abstraction used by the CLI login path.
protocol ManagedCodexDeviceFlowRunning: Sendable {
    func requestDeviceCode() async throws -> CodexDeviceFlow.DeviceCodeResponse
    func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        intervalSeconds: Int,
        deadline: Date) async throws -> CodexOAuthCredentials
}

struct DefaultManagedCodexDeviceFlowRunner: ManagedCodexDeviceFlowRunning {
    private let flow: CodexDeviceFlow

    init(flow: CodexDeviceFlow = CodexDeviceFlow()) {
        self.flow = flow
    }

    func requestDeviceCode() async throws -> CodexDeviceFlow.DeviceCodeResponse {
        try await self.flow.requestDeviceCode()
    }

    func pollForTokens(
        deviceAuthID: String,
        userCode: String,
        intervalSeconds: Int,
        deadline: Date) async throws -> CodexOAuthCredentials
    {
        try await self.flow.pollForTokens(
            deviceAuthID: deviceAuthID,
            userCode: userCode,
            intervalSeconds: intervalSeconds,
            deadline: deadline)
    }
}
