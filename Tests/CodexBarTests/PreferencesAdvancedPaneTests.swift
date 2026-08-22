import Testing
@testable import CodexBar

@MainActor
struct PreferencesAdvancedPaneTests {
    @Test
    func `cli install status prefers successful installs over unrelated failures`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: ["Installed: /opt/homebrew/bin"],
            conflicts: [],
            failures: ["No write access: /usr/local/bin"])

        #expect(status == "Installed: /opt/homebrew/bin")
    }

    @Test
    func `cli install status keeps conflicting executables visible alongside successful installs`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: ["Installed: /opt/homebrew/bin"],
            conflicts: ["Exists: /usr/local/bin"],
            failures: ["No write access: /some/other/bin"])

        #expect(status == "Installed: /opt/homebrew/bin · Exists: /usr/local/bin")
    }

    @Test
    func `cli install status falls back to failures when nothing installed`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: [],
            conflicts: ["Exists: /opt/homebrew/bin"],
            failures: ["No write access: /usr/local/bin"])

        #expect(status == "Exists: /opt/homebrew/bin · No write access: /usr/local/bin")
    }

    @Test
    func `cli install status falls back to failures when there are no successes or conflicts`() {
        let status = AdvancedPane.cliInstallStatus(
            installed: [],
            conflicts: [],
            failures: ["Failed: /opt/homebrew/bin", "No write access: /usr/local/bin"])

        #expect(status == "Failed: /opt/homebrew/bin · No write access: /usr/local/bin")
    }
}
