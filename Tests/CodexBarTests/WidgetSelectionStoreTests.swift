import Foundation
import Testing
@testable import CodexBarCore

struct WidgetSelectionStoreTests {
    @Test
    func `inactive account preview selection stays provider scoped and can be cleared`() throws {
        let suite = "WidgetSelectionStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WidgetSelectionStore.loadSelectedAccount(for: .claude, defaults: defaults) == nil)
        WidgetSelectionStore.saveSelectedAccount("claude-1", for: .claude, defaults: defaults)
        WidgetSelectionStore.saveSelectedAccount("codex-1", for: .codex, defaults: defaults)
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .claude, defaults: defaults) == "claude-1")
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .codex, defaults: defaults) == "codex-1")

        WidgetSelectionStore.saveSelectedAccount("claude-2", for: .claude, defaults: defaults)
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .claude, defaults: defaults) == "claude-2")
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .codex, defaults: defaults) == "codex-1")

        WidgetSelectionStore.saveSelectedAccount("", for: .claude, defaults: defaults)
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .claude, defaults: defaults) == nil)
        #expect(WidgetSelectionStore.loadSelectedAccount(for: .codex, defaults: defaults) == "codex-1")
    }
}
