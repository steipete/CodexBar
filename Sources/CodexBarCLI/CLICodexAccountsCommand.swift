import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func codexAccountsCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "codex-accounts",
            abstract: "List managed Codex accounts or promote one to the system account",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "list",
                    abstract: "List managed accounts without credential contents",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigOptions()).flattened()),
                CommandDescriptor(
                    name: "promote",
                    abstract: "Explicitly replace system auth after preserving its account",
                    discussion: nil,
                    signature: CommandSignature.describe(CodexAccountPromoteOptions()).flattened()),
            ],
            defaultSubcommandName: "list")
    }

    @MainActor
    static func runCodexAccounts(path: [String], values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        #if os(macOS)
        do {
            let store = FileManagedCodexAccountStore()
            let accounts = try store.loadAccounts().accounts
            let liveHome = CodexHomeScope.ambientHomeURL(env: ProcessInfo.processInfo.environment)
            let liveData = try DefaultCodexAuthMaterialReader().readAuthData(homeURL: liveHome)
            let live = try liveData.map { try PreparedPromotionContextBuilder.runtimeAccount(from: $0) }
            if path == ["codex-accounts", "list"] {
                let reader = DefaultCodexAuthMaterialReader()
                var runtimeAccounts: [UUID: CodexAuthBackedAccount] = [:]
                for account in accounts {
                    let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
                    if let data = try reader.readAuthData(homeURL: home) {
                        runtimeAccounts[account.id] = try PreparedPromotionContextBuilder.runtimeAccount(from: data)
                    }
                }
                let rows = Self.codexAccountRows(accounts: accounts, live: live, runtimeAccounts: runtimeAccounts)
                if output.format == .json { Self.printJSON(rows, pretty: output.pretty) } else { for row in rows {
                    print("\(row.isSystemAccount ? "*" : " ") \(row.id) \(row.email)")
                } }
                return
            }
            guard path == ["codex-accounts", "promote"], let selector = values.positional.first else {
                throw CodexAccountCLIError.missingSelector
            }
            let target = try Self.resolveCodexAccount(selector: selector, accounts: accounts)
            let transaction = CodexAccountPromotionTransaction(
                store: store,
                homeFactory: CLICodexManagedHomeFactory(),
                workspaceResolver: CLICodexWorkspaceResolver(),
                snapshotLoader: CLICodexAccountSnapshotLoader(),
                authMaterialReader: DefaultCodexAuthMaterialReader(),
                liveAuthSwapper: DefaultCodexLiveAuthSwapper(),
                baseEnvironment: ProcessInfo.processInfo.environment)
            let result = try await transaction.promoteManagedAccount(id: target.id)
            let receipt = CodexAccountPromotionReceipt(
                id: target.id.uuidString, changedSystemAuth: result.didMutateLiveAuth)
            if output.format == .json { Self.printJSON(receipt, pretty: output.pretty) } else {
                let action = result.didMutateLiveAuth ? "Promoted" : "Already system account:"
                print("\(action) \(target.id.uuidString). Existing Codex processes may retain their current account.")
            }
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
        #else
        Self.exit(
            code: .failure,
            message: "Managed Codex account commands are only available on macOS.",
            output: output,
            kind: .args)
        #endif
    }

    static func resolveCodexAccount(selector: String, accounts: [ManagedCodexAccount]) throws -> ManagedCodexAccount {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(uuidString: normalized)
        let matches = accounts.filter {
            id == nil ? $0.email.caseInsensitiveCompare(normalized) == .orderedSame : $0.id == id
        }
        guard matches.count == 1, let account = matches.first else {
            throw matches.isEmpty ? CodexAccountCLIError.unknownAccount : CodexAccountCLIError.ambiguousAccount
        }
        return account
    }

    static func codexAccountRows(
        accounts: [ManagedCodexAccount],
        live: CodexAuthBackedAccount?,
        runtimeAccounts: [UUID: CodexAuthBackedAccount] = [:]) -> [CodexAccountListRow]
    {
        accounts.map { account in
            CodexAccountListRow(id: account.id.uuidString, email: account.email, isSystemAccount: live.flatMap { live in
                runtimeAccounts[account.id].map { runtime in
                    let identity = account.effectiveWorkspaceAccountID.map { CodexIdentity.providerAccount(id: $0) }
                        ?? runtime.identity
                    return CodexIdentityMatcher.matches(
                        identity,
                        lhsEmail: runtime.email,
                        live.identity,
                        rhsEmail: live.email)
                }
            } ?? false)
        }
    }
}

struct CodexAccountPromoteOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Argument(help: "Exact managed account UUID or unambiguous email") var account: String = ""
}

struct CodexAccountListRow: Encodable {
    let id: String
    let email: String
    let isSystemAccount: Bool
}

private struct CodexAccountPromotionReceipt: Encodable {
    let id: String
    let changedSystemAuth: Bool
}

enum CodexAccountCLIError: Error, LocalizedError, Equatable {
    case missingSelector, unknownAccount, ambiguousAccount, unsafeHome
    var errorDescription: String? {
        switch self {
        case .missingSelector: "Provide a managed account UUID or email."
        case .unknownAccount: "No matching managed Codex account."
        case .ambiguousAccount: "Several managed accounts share that email. Use an exact UUID."
        case .unsafeHome: "Managed account home is outside the managed home directory."
        }
    }
}

private struct CLICodexManagedHomeFactory: ManagedCodexHomeProducing {
    private var root: URL {
        FileManagedCodexAccountStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }

    func makeHomeURL() -> URL { self.root.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    func validateManagedHomeForDeletion(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(self.root.standardizedFileURL.path + "/") else {
            throw CodexAccountCLIError.unsafeHome
        }
    }
}

private struct CLICodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    func resolveWorkspaceIdentity(
        homePath _: String,
        providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        CodexOpenAIWorkspaceIdentity(workspaceAccountID: providerAccountID, workspaceLabel: nil)
    }
}

@MainActor
private struct CLICodexAccountSnapshotLoader: CodexAccountReconciliationSnapshotLoading {
    func loadSnapshot() -> CodexAccountReconciliationSnapshot {
        CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false)
    }
}
