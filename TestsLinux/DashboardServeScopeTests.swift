import Commander
import Testing
@testable import CodexBarCLI

struct DashboardServeScopeTests {
    @Test
    func `live account expansion is an explicit serve only option`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let ordinary = try program.resolve(arguments: ["serve"])
        let expanded = try program.resolve(arguments: ["serve", "--all-accounts"])
        #expect(!ordinary.parsedValues.flags.contains("allAccounts"))
        #expect(expanded.parsedValues.flags.contains("allAccounts"))
        #expect(throws: (any Error).self) { try program.resolve(arguments: ["dashboard", "--all-accounts"]) }
    }
}
