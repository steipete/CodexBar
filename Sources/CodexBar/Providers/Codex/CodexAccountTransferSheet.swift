import AppKit
import CodexBarCore
import Darwin
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sheet state (headless, testable)

enum CodexAccountTransferMode: Equatable {
    case exportAccounts
    case importAccounts
}

/// Transient view state for the account transfer sheet. The password lives only in memory for the lifetime of the
/// sheet and is cleared as soon as an operation completes or the sheet is dismissed. It is never persisted or logged.
struct CodexAccountTransferSheetState: Equatable, CustomStringConvertible {
    enum Outcome: Equatable {
        case exported(fileName: String)
        case imported(CodexAccountTransferReport)
    }

    enum Phase: Equatable {
        case editing
        case working
        case finished(Outcome)
    }

    enum PasswordIssue: Equatable {
        case empty
        case tooShort
        case mismatch
    }

    static let minimumPasswordLength = CodexAccountTransferService.minimumPasswordLength

    var mode: CodexAccountTransferMode
    var password = ""
    var confirmation = ""
    private(set) var phase: Phase = .editing
    private(set) var errorMessage: String?

    init(mode: CodexAccountTransferMode) {
        self.mode = mode
    }

    /// Redacted so the password can never reach a log through string interpolation.
    var description: String {
        "CodexAccountTransferSheetState(mode: \(self.mode), phase: \(self.phase))"
    }

    var isWorking: Bool {
        self.phase == .working
    }

    var isFinished: Bool {
        if case .finished = self.phase { return true }
        return false
    }

    var outcome: Outcome? {
        if case let .finished(outcome) = self.phase { return outcome }
        return nil
    }

    var requiresConfirmation: Bool {
        self.mode == .exportAccounts
    }

    var passwordIssue: PasswordIssue? {
        switch self.mode {
        case .exportAccounts:
            if self.password.count < Self.minimumPasswordLength { return .tooShort }
            if self.password != self.confirmation { return .mismatch }
            return nil
        case .importAccounts:
            return self.password.isEmpty ? .empty : nil
        }
    }

    /// Hint text to show while the user is still typing. Empty fields stay quiet.
    var validationMessage: String? {
        guard self.phase == .editing else { return nil }
        switch self.passwordIssue {
        case .tooShort where !self.password.isEmpty:
            return L("Use at least %d characters.", Self.minimumPasswordLength)
        case .mismatch where !self.confirmation.isEmpty:
            return L("Passwords do not match.")
        default:
            return nil
        }
    }

    var canSubmit: Bool {
        self.phase == .editing && self.passwordIssue == nil
    }

    var canCancel: Bool {
        !self.isWorking
    }

    var allowsEditing: Bool {
        self.phase == .editing
    }

    var title: String {
        switch self.mode {
        case .exportAccounts: L("Export Codex Accounts")
        case .importAccounts: L("Import Codex Accounts")
        }
    }

    var explanation: String {
        switch self.mode {
        case .exportAccounts:
            L(
                "The file contains the sign-in credentials of your added Codex accounts, encrypted with this "
                    + "password. Anyone with the file and password can use those accounts. If you lose the "
                    + "password, the file cannot be recovered.")
        case .importAccounts:
            L(
                "Choose an account file exported from CodexBar and enter its password. Imported accounts are added "
                    + "without changing the system account or your current selection.")
        }
    }

    var submitTitle: String {
        switch self.mode {
        case .exportAccounts: L("Export")
        case .importAccounts: L("Import")
        }
    }

    var summary: String? {
        switch self.outcome {
        case let .exported(fileName):
            L("Saved encrypted file “%@”.", fileName)
        case let .imported(report):
            L(
                "%d imported, %d already present, %d failed.",
                report.importedCount,
                report.existingCount,
                report.failures.count)
        case nil:
            nil
        }
    }

    /// One line per failed account. Contains the account email and a reason, never credential material.
    var failureLines: [String] {
        guard case let .imported(report) = self.outcome else { return [] }
        return report.failures.map { L("%@: %@", $0.email, $0.message) }
    }

    mutating func beginWorking() {
        self.errorMessage = nil
        self.phase = .working
    }

    mutating func finish(_ outcome: Outcome) {
        self.clearSecrets()
        self.errorMessage = nil
        self.phase = .finished(outcome)
    }

    mutating func fail(message: String) {
        self.clearSecrets()
        self.errorMessage = message
        self.phase = .editing
    }

    mutating func clearSecrets() {
        self.password = ""
        self.confirmation = ""
    }
}

// MARK: - Collaborators (injectable)

/// Runs the encryption, file IO, and registry work off the main actor.
protocol CodexAccountTransferPerforming: Sendable {
    /// Encrypts the managed accounts, then atomically writes a private (0600) file at `destination`.
    /// `destination` is untouched unless encryption succeeds.
    func exportPackage(password: String, to destination: URL) async throws
    func importPackage(from source: URL, password: String) async throws -> CodexAccountTransferReport
}

struct DefaultCodexAccountTransferPerformer: CodexAccountTransferPerforming {
    func exportPackage(password: String, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let service = Self.makeService()
            let data = try service.exportAccounts(password: password)
            try CredentialFileWriter.writePrivate(data, to: destination)
        }.value
    }

    func importPackage(from source: URL, password: String) async throws -> CodexAccountTransferReport {
        try await Task.detached(priority: .utility) {
            let data = try CodexAccountTransferFileReader.readPackage(at: source)
            return try Self.makeService().importAccounts(data: data, password: password)
        }.value
    }

    private static func makeService() -> CodexAccountTransferService {
        CodexAccountTransferService(store: FileManagedCodexAccountStore(), homeFactory: ManagedCodexHomeFactory())
    }
}

enum CodexAccountTransferFileError: Error, Equatable, LocalizedError {
    case notRegularFile
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notRegularFile: L("The selected item is not a regular file.")
        case .tooLarge: L("The selected file is larger than the 8 MiB limit.")
        }
    }
}

enum CodexAccountTransferFileReader {
    static let fileExtension = "codexbar-accounts"

    /// Checks the on-disk size before reading, then bounds the read itself so a file that grows cannot exceed the cap.
    static func readPackage(
        at url: URL,
        maximumBytes: Int = CodexAccountTransferService.maximumPackageBytes) throws -> Data
    {
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw CodexAccountTransferFileError.notRegularFile
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else { throw CodexAccountTransferFileError.tooLarge }

        // Revalidate the opened descriptor: the selected file can change after the attribute check.
        let descriptor = resolved.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw CodexAccountTransferFileError.notRegularFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw CodexAccountTransferFileError.notRegularFile }
        guard openedStatus.st_size >= 0, openedStatus.st_size <= maximumBytes else {
            throw CodexAccountTransferFileError.tooLarge
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CodexAccountTransferFileError.tooLarge }
        return data
    }
}

/// File panel seams. Panels are only presented from a user-initiated button press, never automatically.
struct CodexAccountTransferPanels {
    var chooseExportDestination: @MainActor () -> URL?
    var chooseImportSource: @MainActor () -> URL?

    static func appKit() -> CodexAccountTransferPanels {
        CodexAccountTransferPanels(
            chooseExportDestination: {
                let panel = NSSavePanel()
                panel.title = L("Export Codex Accounts")
                panel.message = L("Encrypted CodexBar account file")
                panel.prompt = L("Export")
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                if let type = UTType(filenameExtension: CodexAccountTransferFileReader.fileExtension) {
                    panel.allowedContentTypes = [type]
                }
                panel.nameFieldStringValue = "codex-accounts.\(CodexAccountTransferFileReader.fileExtension)"
                guard panel.runModal() == .OK else { return nil }
                return panel.url
            },
            chooseImportSource: {
                let panel = NSOpenPanel()
                panel.title = L("Import Codex Accounts")
                panel.message = L("Choose an encrypted CodexBar account file.")
                panel.prompt = L("Import")
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.data]
                guard panel.runModal() == .OK else { return nil }
                return panel.url
            })
    }
}

// MARK: - Flow model

@MainActor
@Observable
final class CodexAccountTransferModel {
    private(set) var isPresented = false
    var state = CodexAccountTransferSheetState(mode: .exportAccounts)
    private(set) var isRefreshing = false

    @ObservationIgnored private let performer: any CodexAccountTransferPerforming
    @ObservationIgnored private let panels: CodexAccountTransferPanels

    init(
        performer: any CodexAccountTransferPerforming = DefaultCodexAccountTransferPerformer(),
        panels: CodexAccountTransferPanels = .appKit())
    {
        self.performer = performer
        self.panels = panels
    }

    /// True while crypto, file IO, or the post-import refresh is running. Other account operations are blocked.
    var isBusy: Bool {
        self.state.isWorking || self.isRefreshing
    }

    func present(_ mode: CodexAccountTransferMode) {
        guard !self.isBusy else { return }
        self.state = CodexAccountTransferSheetState(mode: mode)
        self.isPresented = true
    }

    /// Closes the sheet and discards the password. Ignored while an operation is running.
    func dismiss() {
        guard !self.isBusy else { return }
        self.state.clearSecrets()
        self.isPresented = false
    }

    /// Runs the operation for the current mode. `afterImport` runs once after a completed import so the managed
    /// account list refreshes; it never selects or promotes an imported account.
    func run(afterImport: @MainActor () async -> Void) async {
        guard self.isPresented, !self.isBusy, self.state.canSubmit else { return }
        let password = self.state.password
        switch self.state.mode {
        case .exportAccounts:
            guard let destination = self.panels.chooseExportDestination() else { return }
            self.state.beginWorking()
            do {
                try await self.performer.exportPackage(password: password, to: destination)
                self.state.finish(.exported(fileName: destination.lastPathComponent))
            } catch {
                self.state.fail(message: error.localizedDescription)
            }
        case .importAccounts:
            guard let source = self.panels.chooseImportSource() else { return }
            self.state.beginWorking()
            do {
                let report = try await self.performer.importPackage(from: source, password: password)
                self.isRefreshing = true
                self.state.finish(.imported(report))
                await afterImport()
                self.isRefreshing = false
            } catch {
                self.state.fail(message: error.localizedDescription)
            }
        }
    }
}

// MARK: - View

struct CodexAccountTransferSheet: View {
    @Bindable var model: CodexAccountTransferModel
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.model.state.title)
                .font(.headline)

            if let summary = self.model.state.summary {
                self.resultContent(summary: summary)
            } else {
                self.formContent
            }

            HStack(spacing: 8) {
                if self.model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Working…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                self.buttons
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(self.model.isBusy)
    }

    @ViewBuilder
    private var formContent: some View {
        Text(self.model.state.explanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SecureField(L("Password"), text: self.$model.state.password)
            .textFieldStyle(.roundedBorder)
            .disabled(!self.model.state.allowsEditing)
        if self.model.state.requiresConfirmation {
            SecureField(L("Confirm password"), text: self.$model.state.confirmation)
                .textFieldStyle(.roundedBorder)
                .disabled(!self.model.state.allowsEditing)
        }

        if let message = self.model.state.validationMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let error = self.model.state.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func resultContent(summary: String) -> some View {
        Text(summary)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(self.model.state.failureLines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if self.model.state.isFinished {
            Button(L("Done")) { self.model.dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(self.model.isBusy)
        } else {
            Button(L("Cancel")) { self.model.dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(!self.model.state.canCancel)
            Button(self.model.state.submitTitle) { self.submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!self.model.state.canSubmit)
        }
    }
}
