import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLIOutputTests {
    @Test
    func outputPreferencesJsonOnlyForcesJSON() {
        let output = CLIOutputPreferences.from(argv: ["--json-only"])
        #expect(output.jsonOnly == true)
        #expect(output.format == .json)
    }

    @Test
    func cliErrorPayloadIsJSONArray() throws {
        let payload = CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            pretty: false)
        #expect(payload != nil)
        let data = payload?.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(json?.isEmpty == false)
        let first = json?.first as? [String: Any]
        #expect(first?["provider"] as? String == "cli")
        let error = first?["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Nope")
    }
}
