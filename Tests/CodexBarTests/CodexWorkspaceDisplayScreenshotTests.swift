import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class CodexWorkspaceDisplayScreenshotTests: XCTestCase {
    func test_renderSyntheticWorkspaceLabels() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_WORKSPACE_LABEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WORKSPACE_LABEL_PROOF_DIR for synthetic account-label proof.")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else {
            return XCTFail("Screenshot proof requires credential and session isolation.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = CodexWorkspaceDisplayTests.accounts(label: nil)
        let projected = CodexWorkspaceDisplayTests.project(original).visibleAccounts
        let crowded = CodexWorkspaceDisplayTests.project(
            CodexWorkspaceDisplayTests.accounts(label: nil, count: 8)).visibleAccounts
        for (name, accounts) in [("before", original), ("after", projected), ("eight-accounts", crowded)] {
            let state = CodexAccountsSectionState(
                visibleAccounts: accounts,
                activeVisibleAccountID: accounts[0].id,
                liveVisibleAccountID: accounts[0].id,
                hasUnreadableManagedAccountStore: false,
                isAuthenticatingManagedAccount: false,
                authenticatingManagedAccountID: nil,
                isRemovingManagedAccount: false,
                isAuthenticatingLiveAccount: false,
                isPromotingSystemAccount: false,
                notice: nil)
            let content = VStack(alignment: .leading, spacing: 18) {
                Text("Synthetic Codex workspace accounts").font(.title2.bold())
                CodexAccountsSectionView(
                    state: state,
                    setActiveVisibleAccount: { _ in },
                    reauthenticateAccount: { _ in },
                    removeAccount: { _ in },
                    requestSystemVisibleAccount: { _ in },
                    addAccount: {})
                Divider()
                Text("Menu account switcher").font(.headline)
                WorkspaceProofSwitcher(accounts: accounts).frame(width: 310, height: accounts.count > 3 ? 56 : 26)
            }
            .padding(24)
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            let hosting = NSHostingView(rootView: content)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer {
                window.contentView = nil
                window.close()
            }
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("workspace-labels-\(name).png"))
        }
    }
}

private struct WorkspaceProofSwitcher: NSViewRepresentable {
    let accounts: [CodexVisibleAccount]

    func makeNSView(context: Context) -> CodexAccountSwitcherView {
        CodexAccountSwitcherView(
            accounts: self.accounts, selectedAccountID: self.accounts[0].id, width: 310, onSelect: { _ in })
    }

    func updateNSView(_ nsView: CodexAccountSwitcherView, context: Context) {}
}
