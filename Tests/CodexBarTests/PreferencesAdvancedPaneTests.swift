import Testing
@testable import CodexBar

struct PreferencesAdvancedPaneTests {
    @Test
    func `cli install status prefers successful installs over unrelated failures`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: ["Installed: /opt/homebrew/bin"],
            failures: ["No write access: /usr/local/bin"])

        #expect(status == "Installed: /opt/homebrew/bin")
    }

    @Test
    func `cli install status falls back to failures when nothing installed`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: [],
            failures: ["Exists: /opt/homebrew/bin", "No write access: /usr/local/bin"])

        #expect(status == "Exists: /opt/homebrew/bin · No write access: /usr/local/bin")
    }
}
