import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountTransferUIStateTests {
    private static let validPassword = "correct horse battery"

    private final class FakePerformer: CodexAccountTransferPerforming, @unchecked Sendable {
        var exportError: Error?
        var importResult: Result<CodexAccountTransferReport, Error> = .success(
            CodexAccountTransferReport(importedCount: 0, existingCount: 0, failures: []))
        private(set) var exportedPasswords: [String] = []
        private(set) var exportedDestinations: [URL] = []
        private(set) var importedSources: [URL] = []

        func exportPackage(password: String, to destination: URL) async throws {
            self.exportedPasswords.append(password)
            self.exportedDestinations.append(destination)
            if let exportError { throw exportError }
        }

        func importPackage(from source: URL, password _: String) async throws -> CodexAccountTransferReport {
            self.importedSources.append(source)
            return try self.importResult.get()
        }
    }

    private struct SyntheticError: LocalizedError {
        var errorDescription: String? {
            "synthetic failure"
        }
    }

    private static func account(stored: Bool) -> CodexVisibleAccount {
        let id = UUID()
        return CodexVisibleAccount(
            id: "managed:\(id.uuidString.lowercased())",
            email: "user@example.com",
            storedAccountID: stored ? id : nil,
            selectionSource: stored ? .managedAccount(id: id) : .liveSystem,
            isActive: true,
            isLive: !stored,
            canReauthenticate: true,
            canRemove: stored)
    }

    private static func sectionState(
        accounts: [CodexVisibleAccount],
        unreadable: Bool = false,
        authenticating: Bool = false,
        removing: Bool = false,
        liveAuthenticating: Bool = false,
        promoting: Bool = false,
        transferring: Bool = false) -> CodexAccountsSectionState
    {
        CodexAccountsSectionState(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts.first?.id,
            liveVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: unreadable,
            isAuthenticatingManagedAccount: authenticating,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: removing,
            isAuthenticatingLiveAccount: liveAuthenticating,
            isPromotingSystemAccount: promoting,
            notice: nil,
            isTransferringAccounts: transferring)
    }

    private static func model(
        performer: FakePerformer = FakePerformer(),
        exportURL: URL? = URL(fileURLWithPath: "/tmp/synthetic.codexbar-accounts"),
        importURL: URL? = URL(fileURLWithPath: "/tmp/synthetic-import.codexbar-accounts"))
        -> CodexAccountTransferModel
    {
        CodexAccountTransferModel(
            performer: performer,
            panels: CodexAccountTransferPanels(
                chooseExportDestination: { exportURL },
                chooseImportSource: { importURL }))
    }

    // MARK: Buttons and gating

    @Test
    func `export requires a stored managed account`() {
        #expect(Self.sectionState(accounts: [Self.account(stored: true)]).canExportAccounts)
        #expect(!Self.sectionState(accounts: []).canExportAccounts)
        #expect(!Self.sectionState(accounts: [Self.account(stored: false)]).canExportAccounts)
    }

    @Test
    func `export and import are blocked by an unreadable store`() {
        let state = Self.sectionState(accounts: [Self.account(stored: true)], unreadable: true)
        #expect(!state.canExportAccounts)
        #expect(!state.canImportAccounts)
    }

    @Test
    func `import is allowed without accounts and follows add account gating`() {
        let empty = Self.sectionState(accounts: [])
        #expect(empty.canImportAccounts)
        #expect(empty.canImportAccounts == empty.canAddAccount)
    }

    @Test
    func `every conflicting operation disables transfer and other account actions`() {
        let stored = Self.account(stored: true)
        let busyStates = [
            Self.sectionState(accounts: [stored], authenticating: true),
            Self.sectionState(accounts: [stored], removing: true),
            Self.sectionState(accounts: [stored], liveAuthenticating: true),
            Self.sectionState(accounts: [stored], promoting: true),
            Self.sectionState(accounts: [stored], transferring: true),
        ]
        for state in busyStates {
            #expect(!state.canExportAccounts)
            #expect(!state.canImportAccounts)
            #expect(!state.canAddAccount)
        }
    }

    @Test
    func `an in-flight transfer blocks removal reauthentication and system promotion`() {
        let stored = Self.account(stored: true)
        let state = Self.sectionState(accounts: [stored, Self.account(stored: true)], transferring: true)
        #expect(state.hasAccountOperationInFlight)
        #expect(!state.canRemove(stored))
        #expect(!state.canReauthenticate(stored))
        #expect(!state.canPromoteToSystem(stored))
        #expect(state.isSystemSelectionDisabled)
    }

    // MARK: Password validation

    @Test
    func `export needs a long enough password that matches its confirmation`() {
        var state = CodexAccountTransferSheetState(mode: .exportAccounts)
        #expect(!state.canSubmit)
        #expect(state.validationMessage == nil)

        state.password = "short"
        state.confirmation = "short"
        #expect(state.passwordIssue == .tooShort)
        #expect(!state.canSubmit)
        #expect(state.validationMessage != nil)

        state.password = String(repeating: "a", count: CodexAccountTransferSheetState.minimumPasswordLength - 1)
        #expect(!state.canSubmit)
        state.password = String(repeating: "a", count: CodexAccountTransferSheetState.minimumPasswordLength)
        state.confirmation = String(repeating: "b", count: CodexAccountTransferSheetState.minimumPasswordLength)
        #expect(state.passwordIssue == .mismatch)
        #expect(!state.canSubmit)

        state.confirmation = state.password
        #expect(state.passwordIssue == nil)
        #expect(state.canSubmit)
        #expect(state.validationMessage == nil)
    }

    @Test
    func `import accepts any non empty password without confirmation`() {
        var state = CodexAccountTransferSheetState(mode: .importAccounts)
        #expect(!state.requiresConfirmation)
        #expect(!state.canSubmit)
        state.password = "x"
        #expect(state.canSubmit)
    }

    @Test
    func `state description never includes the password`() {
        var state = CodexAccountTransferSheetState(mode: .exportAccounts)
        state.password = Self.validPassword
        state.confirmation = Self.validPassword
        #expect(!"\(state)".contains(Self.validPassword))
        #expect(!String(describing: state).contains(Self.validPassword))
    }

    // MARK: Cancel and busy

    @Test
    func `cancel discards the password and closes the sheet`() {
        let model = Self.model()
        model.present(.exportAccounts)
        model.state.password = Self.validPassword
        model.state.confirmation = Self.validPassword
        #expect(model.isPresented)

        model.dismiss()
        #expect(!model.isPresented)
        #expect(model.state.password.isEmpty)
        #expect(model.state.confirmation.isEmpty)
    }

    @Test
    func `working state disables cancel and editing`() {
        var state = CodexAccountTransferSheetState(mode: .exportAccounts)
        state.password = Self.validPassword
        state.confirmation = Self.validPassword
        state.beginWorking()
        #expect(state.isWorking)
        #expect(!state.canCancel)
        #expect(!state.canSubmit)
        #expect(!state.allowsEditing)
    }

    @Test
    func `dismiss and present are ignored while busy`() {
        let model = Self.model()
        model.present(.importAccounts)
        model.state.password = Self.validPassword
        model.state.beginWorking()
        #expect(model.isBusy)

        model.dismiss()
        #expect(model.isPresented)
        model.present(.exportAccounts)
        #expect(model.state.mode == .importAccounts)
    }

    // MARK: Export flow

    @Test
    func `export passes the password and destination then clears secrets`() async {
        let performer = FakePerformer()
        let model = Self.model(performer: performer)
        model.present(.exportAccounts)
        model.state.password = Self.validPassword
        model.state.confirmation = Self.validPassword

        await model.run(afterImport: { Issue.record("export must not refresh providers") })

        #expect(performer.exportedPasswords == [Self.validPassword])
        #expect(performer.exportedDestinations.map(\.lastPathComponent) == ["synthetic.codexbar-accounts"])
        #expect(model.state.outcome == .exported(fileName: "synthetic.codexbar-accounts"))
        #expect(model.state.password.isEmpty)
        #expect(model.state.confirmation.isEmpty)
        #expect(!model.isBusy)
    }

    @Test
    func `export cancelled at the file panel does nothing`() async {
        let performer = FakePerformer()
        let model = Self.model(performer: performer, exportURL: nil)
        model.present(.exportAccounts)
        model.state.password = Self.validPassword
        model.state.confirmation = Self.validPassword

        await model.run(afterImport: {})

        #expect(performer.exportedPasswords.isEmpty)
        #expect(model.state.allowsEditing)
        #expect(!model.state.isFinished)
    }

    @Test
    func `export failure shows the message and clears the password`() async {
        let performer = FakePerformer()
        performer.exportError = SyntheticError()
        let model = Self.model(performer: performer)
        model.present(.exportAccounts)
        model.state.password = Self.validPassword
        model.state.confirmation = Self.validPassword

        await model.run(afterImport: {})

        #expect(model.state.errorMessage == "synthetic failure")
        #expect(model.state.password.isEmpty)
        #expect(!model.state.isFinished)
        #expect(!model.isBusy)
    }

    @Test
    func `invalid export input never reaches the performer`() async {
        let performer = FakePerformer()
        let model = Self.model(performer: performer)
        model.present(.exportAccounts)
        model.state.password = Self.validPassword
        model.state.confirmation = "different password"

        await model.run(afterImport: {})

        #expect(performer.exportedPasswords.isEmpty)
    }

    // MARK: Import flow

    @Test
    func `import reports counts and per account failures then refreshes once`() async {
        let performer = FakePerformer()
        performer.importResult = .success(CodexAccountTransferReport(
            importedCount: 2,
            existingCount: 1,
            failures: [CodexAccountTransferFailure(email: "bad@example.com", message: "Could not be saved.")]))
        let model = Self.model(performer: performer)
        model.present(.importAccounts)
        model.state.password = Self.validPassword

        var refreshCount = 0
        var busyDuringRefresh = false
        await model.run(afterImport: {
            refreshCount += 1
            busyDuringRefresh = model.isBusy
        })

        #expect(refreshCount == 1)
        #expect(busyDuringRefresh)
        #expect(!model.isBusy)
        #expect(performer.importedSources.map(\.lastPathComponent) == ["synthetic-import.codexbar-accounts"])
        #expect(model.state.summary == L("%d imported, %d already present, %d failed.", 2, 1, 1))
        #expect(model.state.failureLines == [L("%@: %@", "bad@example.com", "Could not be saved.")])
        #expect(model.state.password.isEmpty)
    }

    @Test
    func `import failure does not refresh and keeps the sheet open for retry`() async {
        let performer = FakePerformer()
        performer.importResult = .failure(SyntheticError())
        let model = Self.model(performer: performer)
        model.present(.importAccounts)
        model.state.password = Self.validPassword

        await model.run(afterImport: { Issue.record("failed import must not refresh") })

        #expect(model.isPresented)
        #expect(model.state.errorMessage == "synthetic failure")
        #expect(model.state.password.isEmpty)
        #expect(!model.state.isFinished)
    }

    @Test
    func `import cancelled at the file panel does nothing`() async {
        let performer = FakePerformer()
        let model = Self.model(performer: performer, importURL: nil)
        model.present(.importAccounts)
        model.state.password = Self.validPassword

        await model.run(afterImport: { Issue.record("cancelled import must not refresh") })

        #expect(performer.importedSources.isEmpty)
        #expect(model.state.allowsEditing)
    }

    // MARK: File size cap

    @Test
    func `package reader rejects files over the cap before returning data`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transfer-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let small = directory.appendingPathComponent("small.codexbar-accounts")
        try Data(repeating: 1, count: 16).write(to: small)
        #expect(try CodexAccountTransferFileReader.readPackage(at: small, maximumBytes: 16).count == 16)

        let large = directory.appendingPathComponent("large.codexbar-accounts")
        try Data(repeating: 1, count: 17).write(to: large)
        #expect(throws: CodexAccountTransferFileError.tooLarge) {
            try CodexAccountTransferFileReader.readPackage(at: large, maximumBytes: 16)
        }
        #expect(throws: CodexAccountTransferFileError.notRegularFile) {
            try CodexAccountTransferFileReader.readPackage(at: directory, maximumBytes: 16)
        }
    }

    @Test
    func `package cap matches the core limit of eight mebibytes`() {
        #expect(CodexAccountTransferService.maximumPackageBytes == 8 * 1024 * 1024)
    }
}
