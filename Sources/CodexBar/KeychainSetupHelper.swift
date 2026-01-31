import AppKit
import CodexBarCore
import Foundation
import Security
import SweetCookieKit

/// Helper for guiding users through Chrome Safe Storage keychain setup.
///
/// Chrome Safe Storage is owned by Chrome, so CodexBar cannot programmatically
/// add itself to the ACL. This helper detects when setup is needed and guides
/// users through the manual process.
enum KeychainSetupHelper {
    private static let log = CodexBarLog.logger(LogCategories.keychainSetup)

    /// Status of Chrome Safe Storage access
    enum AccessStatus: Equatable {
        case allowed
        case needsSetup
        case notFound
        case keychainDisabled
    }

    /// Check if Chrome Safe Storage requires user setup
    static func checkChromeSafeStorageAccess() -> AccessStatus {
        guard !KeychainAccessGate.isDisabled else {
            return .keychainDisabled
        }

        // Check all known Chrome Safe Storage variants
        for label in Browser.safeStorageLabels {
            let outcome = KeychainAccessPreflight.checkGenericPassword(
                service: label.service,
                account: label.account
            )
            switch outcome {
            case .allowed:
                self.log.debug("Chrome Safe Storage access allowed", metadata: ["service": label.service])
                return .allowed
            case .interactionRequired:
                self.log.info("Chrome Safe Storage needs setup", metadata: ["service": label.service])
                return .needsSetup
            case .notFound, .failure:
                continue
            }
        }

        return .notFound
    }

    /// Open Keychain Access app and search for Chrome Safe Storage
    static func openKeychainAccessForSetup() {
        self.log.info("Opening Keychain Access for Chrome Safe Storage setup")

        // First, open Keychain Access
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))

        // Give it a moment to open, then use AppleScript to search
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.searchInKeychainAccess(for: "Chrome Safe Storage")
        }
    }

    /// Use AppleScript to search for an item in Keychain Access
    private static func searchInKeychainAccess(for searchTerm: String) {
        // AppleScript to activate Keychain Access and trigger search
        let script = """
        tell application "Keychain Access"
            activate
        end tell

        delay 0.3

        tell application "System Events"
            tell process "Keychain Access"
                -- Focus the search field (Cmd+F or click search)
                keystroke "f" using command down
                delay 0.2
                -- Type the search term
                keystroke "\(searchTerm)"
            end tell
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                // AppleScript might fail due to permissions, but Keychain Access should still be open
                self.log.warning(
                    "AppleScript search failed (Keychain Access still open)",
                    metadata: ["error": String(describing: error)]
                )
            }
        }
    }

    /// Instructions for manual setup (for display in UI)
    static let setupInstructions: [String] = [
        "1. Double-click \"Chrome Safe Storage\" in the list",
        "2. Click the \"Access Control\" tab",
        "3. Click \"+\" and add CodexBar.app from /Applications",
        "4. Click \"Save Changes\" and enter your password",
    ]

    /// Check if any Chromium browser is installed that would need this setup
    static func hasChromiumBrowserInstalled() -> Bool {
        let chromiumBrowsers = [
            "/Applications/Google Chrome.app",
            "/Applications/Microsoft Edge.app",
            "/Applications/Brave Browser.app",
            "/Applications/Arc.app",
            "/Applications/Vivaldi.app",
            "/Applications/Chromium.app",
        ]

        let fm = FileManager.default
        return chromiumBrowsers.contains { fm.fileExists(atPath: $0) }
    }
}

// MARK: - Log Category

extension LogCategories {
    static let keychainSetup = "keychain-setup"
}
