import Testing
@testable import CodexBarCLI

struct CLITimeZoneBootstrapTests {
    @Test
    func `uses localtime file when timezone is unset`() {
        #expect(CodexBarCLI.linuxTimeZoneFallback(
            currentValue: nil,
            localTimeReadable: true) == ":/etc/localtime")
    }

    @Test(arguments: ["Asia/Kolkata", "", ":/custom/zoneinfo"])
    func `preserves caller timezone`(currentValue: String) {
        #expect(CodexBarCLI.linuxTimeZoneFallback(
            currentValue: currentValue,
            localTimeReadable: true) == nil)
    }

    @Test
    func `does not set an unreadable localtime file`() {
        #expect(CodexBarCLI.linuxTimeZoneFallback(
            currentValue: nil,
            localTimeReadable: false) == nil)
    }
}
