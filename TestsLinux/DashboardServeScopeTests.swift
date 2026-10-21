import Commander
import Testing
@testable import CodexBarCLI

struct DashboardServeScopeTests {
    @Test
    func `live account expansion is an explicit serve only option`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let ordinary = try program.resolve(argv: ["serve"])
        let expanded = try program.resolve(argv: ["serve", "--all-accounts"])
        #expect(!ordinary.parsedValues.flags.contains("allAccounts"))
        #expect(expanded.parsedValues.flags.contains("allAccounts"))
        #expect(throws: (any Error).self) { try program.resolve(argv: ["dashboard", "--all-accounts"]) }
    }
}
