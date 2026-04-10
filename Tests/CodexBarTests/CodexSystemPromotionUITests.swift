import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexSystemPromotionUITests {
    @Test
    func `promotion coordinator promotes immediately`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-coordinator-immediate")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")

        let managedVisibleAccountID = try #require(container.settings.codexVisibleAccountProjection.visibleAccounts
            .first(where: { $0.storedAccountID == target.id })?
            .id)
        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())

        let result = await coordinator.promote(managedAccountID: target.id)

        let promotionResult: CodexAccountPromotionResult
        switch result {
        case let .success(value):
            promotionResult = value
        case let .failure(error):
            Issue.record("Expected successful promotion, got \(error)")
            throw PromotionTestError.unexpectedDisposition
        }

        #expect(promotionResult.outcome == .promoted)
        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(container.settings.codexVisibleAccountProjection.liveVisibleAccountID == managedVisibleAccountID)
        #expect(coordinator.userFacingError == nil)
    }

    @Test
    func `promotion coordinator blocks while live reauthentication is running`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-coordinator-live-reauth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")
        container.settings.codexActiveSource = .managedAccount(id: target.id)

        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())
        coordinator.setLiveReauthenticationInProgress(true)

        let result = await coordinator.promote(managedAccountID: target.id)

        let error: CodexSystemAccountPromotionUserFacingError
        switch result {
        case .success:
            Issue.record("Expected blocked promotion while live reauthentication is running")
            throw PromotionTestError.unexpectedDisposition
        case let .failure(value):
            error = value
        }

        #expect(error.title == "Could not switch system account")
        #expect(error.message == "Finish the current managed account change before switching the system account.")
        #expect(coordinator.userFacingError == error)
        #expect(coordinator.isInteractionBlocked())
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `codex menu descriptor includes system account submenu`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-menu-descriptor")
        defer { container.tearDown() }

        let managedAccountID = UUID()
        let managedAccount = try container.createManagedAccount(
            id: managedAccountID,
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([managedAccount])
        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date())

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: container.usageStore,
            settings: container.settings,
            account: UsageFetcher().loadAccountInfo(),
            managedCodexAccountCoordinator: ManagedCodexAccountCoordinator(),
            codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator(
                service: container.makeService()),
            updateReady: false)

        let submenu = try #require(descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> (String, String?, [MenuDescriptor.SubmenuItem])? in
                guard case let .submenu(title, systemImageName, items) = entry else { return nil }
                return (title, systemImageName, items)
            }
            .first(where: { $0.0 == "System Account" }))

        #expect(submenu.1 == MenuDescriptor.MenuActionSystemImage.systemAccount.rawValue)
        #expect(submenu.2.map(\.title) == ["live@example.com", "managed@example.com"])
        #expect(submenu.2.count == 2)
        #expect(submenu.2[0].isChecked)
        #expect(submenu.2[0].isEnabled == false)
        #expect(submenu.2[0].action == nil)
        #expect(submenu.2[1].isChecked == false)
        #expect(submenu.2[1].isEnabled)
        #expect(submenu.2[1].action == .requestCodexSystemPromotion(managedAccountID))
    }
}
