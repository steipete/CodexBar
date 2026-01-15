import CodexBarCore
import Testing

@Test("AntigravityLoginRunner process line matching")
func antigravityLoginRunnerProcessLine() throws {
    let validLine = "12345 /usr/local/bin/language_server_macos --csrf_token=test123 --refresh_token=rt456"
    let invalidLine = "67890 /usr/bin/other --other=flag"

    let validResult = type(of: AntigravityLoginRunner).method(named: "matchProcessLine")?()(validLine)
    let invalidResult = type(of: AntigravityLoginRunner).method(named: "matchProcessLine")?()(invalidLine)

    #expect(validResult?.pid == 12345)
    #expect(validResult?.command.contains("language_server_macos"))
    #expect(invalidResult == nil)
}

@Test("AntigravityLoginRunner flag extraction")
func antigravityLoginRunnerFlagExtraction() throws {
    let command = "/usr/local/bin/language_server_macos --csrf_token=token123 --refresh_token=rt456 --project_id=proj789"
    let emptyResult = type(of: AntigravityLoginRunner).method(named: "extractFlag")?()(command, from: "--nonexistent_flag")
    let csrfResult = type(of: AntigravityLoginRunner).method(named: "extractFlag")?()(command, from: "--csrf_token")
    let refreshResult = type(of: AntigravityLoginRunner).method(named: "extractFlag")?()(command, from: "--refresh_token")
    let projectResult = type(of: AntigravityLoginRunner).method(named: "extractFlag")?()(command, from: "--project_id")

    #expect(emptyResult == nil)
    #expect(csrfResult == "token123")
    #expect(refreshResult == "rt456")
    #expect(projectResult == "proj789")
}