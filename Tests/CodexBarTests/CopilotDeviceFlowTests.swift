import CodexBarCore
import Foundation
import Testing

struct CopilotDeviceFlowTests {
    @Test
    func `prefers verification uri complete when available`() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "verification_uri_complete": "https://github.com/login/device?user_code=ABCD-EFGH",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8))

        #expect(response.verificationURLToOpen == "https://github.com/login/device?user_code=ABCD-EFGH")
    }

    @Test
    func `falls back to verification uri when complete url missing`() throws {
        let response = try JSONDecoder().decode(
            CopilotDeviceFlow.DeviceCodeResponse.self,
            from: Data(
                """
                {
                  "device_code": "device-code",
                  "user_code": "ABCD-EFGH",
                  "verification_uri": "https://github.com/login/device",
                  "expires_in": 900,
                  "interval": 5
                }
                """.utf8))

        #expect(response.verificationURLToOpen == "https://github.com/login/device")
    }
}
