import Foundation
import Testing
@testable import CodexBarCLI

struct CLIOutputTests {
    @Test
    func `output preferences json only forces JSON`() {
        let output = CLIOutputPreferences.from(argv: ["--json-only"])
        #expect(output.jsonOnly == true)
        #expect(output.format == .json)
    }

    @Test
    func `cli error payload is JSON array`() throws {
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

    @Test
    func `exit omits generic error when command already emitted payload`() {
        #expect(!CodexBarCLI.shouldPrintExitError(code: .success, message: nil))
        #expect(!CodexBarCLI.shouldPrintExitError(code: .failure, message: nil))
        #expect(CodexBarCLI.shouldPrintExitError(code: .failure, message: "Nope"))
    }
}
