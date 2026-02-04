import Testing
@testable import CodexBar

@Suite
struct KeychainMigrationTests {
    @Test
    func migrationListCoversKnownKeychainItems() {
        let items = Set(KeychainMigration.itemsToMigrate.map(\.label))
        let expected: Set<String> = [
            "com.steipete.CodexBar:codex-cookie",
            "com.steipete.CodexBar:claude-cookie",
            "com.steipete.CodexBar:cursor-cookie",
            "com.steipete.CodexBar:factory-cookie",
            "com.steipete.CodexBar:minimax-cookie",
            "com.steipete.CodexBar:minimax-api-token",
            "com.steipete.CodexBar:augment-cookie",
            "com.steipete.CodexBar:copilot-api-token",
            "com.steipete.CodexBar:zai-api-token",
            "com.steipete.CodexBar:synthetic-api-key",
            "Claude Code-credentials:<any>",
        ]

        let missing = expected.subtracting(items)
        #expect(missing.isEmpty, "Missing migration entries: \(missing.sorted())")
    }

    @Test
    func claudeMigrationTrackingResets() {
        KeychainMigration._resetClaudeMigrationTrackingForTesting()
        // Should not crash when resetting.
        #expect(true)
    }
}
